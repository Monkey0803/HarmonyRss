/*
 * SyncService.ets — 云同步的门面（单例）。
 *
 * 职责：
 *   1. 维护开关、仅 Wi-Fi、节点 id、上次同步时间（偏好库，默认关闭）；
 *   2. 组装 Backend（第一批是本机 Mock）+ 同步表 + 采集器；
 *   3. 对外暴露「状态查询 / 立即同步 / 自动同步 / 重置模拟远端」。
 *
 * 自动同步由三个时机触发（冷启动 / 回前台 / 抓取完成），共用 `autoSync`：
 * 60 秒内只跑一次；失败按 30s / 60s / 120s 退避重试三次，用尽后等下一次触发。
 * 开关关闭、正在同步、仅 Wi-Fi 模式下不是 Wi-Fi 时一律静默跳过。
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';
import { SyncConflict, SyncSummary } from '../model/Sync';
import { articleDatabase } from './ArticleServices';
import { NetworkStatus } from './NetworkStatus';
import { AutoSyncPolicy } from './sync/AutoSyncPolicy';
import { SyncCollector } from './sync/SyncCollector';
import { SyncEngine } from './sync/SyncEngine';
import { syncStore, SyncLimits } from './sync/SyncStore';
import { MockSyncBackend } from './sync/MockSyncBackend';
import { CloudAvailability, cloudStore } from './sync/CloudStore';
import { CloudRelayBackend } from './sync/CloudRelayBackend';
import { SyncBackend } from './sync/SyncBackend';

const DOMAIN: number = 0x0000;
const TAG: string = 'SyncService';

/** 偏好库里冲突概要的原始形状（只读，逐字段校验后再用）。 */
interface ConflictRaw {
  key?: string;
  kind?: string;
  fields?: string[];
}

/** 落盘用的紧凑结构（类而不是对象字面量：ArkTS 要求显式类型）。 */
class ConflictRow {
  key: string = '';
  kind: string = '';
  fields: string[] = [];
}

/** 每个冲突最多记这么多字段名：详情是给人扫一眼的，不是调试工具。 */
const MAX_CONFLICT_FIELDS: number = 6;

/** 冲突概要编码：空数组存空串，避免偏好库里挂一个 `[]`。 */
export function encodeConflictDetails(items: SyncConflict[]): string {
  const rows: ConflictRow[] = [];
  for (let i = 0; i < items.length && i < SyncLimits.CONFLICT_DETAILS; i += 1) {
    const row: ConflictRow = new ConflictRow();
    row.key = items[i].key;
    row.kind = items[i].kind;
    row.fields = items[i].fields.slice(0, MAX_CONFLICT_FIELDS);
    rows.push(row);
  }
  return rows.length > 0 ? JSON.stringify(rows) : '';
}

/** 冲突概要解码：脏数据 / 缺字段一律跳过（纯函数，可单测）。 */
export function decodeConflictDetails(raw: string): SyncConflict[] {
  if (raw.length === 0) {
    return [];
  }
  try {
    const parsed: Object = JSON.parse(raw) as Object;
    if (!Array.isArray(parsed)) {
      return [];
    }
    const values: Object[] = parsed as Object[];
    const result: SyncConflict[] = [];
    for (let i = 0; i < values.length && result.length < SyncLimits.CONFLICT_DETAILS; i += 1) {
      const row: ConflictRaw = values[i] as ConflictRaw;
      if (typeof row.key !== 'string' || row.key.length === 0 ||
        typeof row.kind !== 'string' || row.kind.length === 0) {
        continue;
      }
      const fields: string[] = [];
      if (Array.isArray(row.fields)) {
        const rawFields: string[] = row.fields;
        for (let j = 0; j < rawFields.length && fields.length < MAX_CONFLICT_FIELDS; j += 1) {
          if (typeof rawFields[j] === 'string' && rawFields[j].length > 0) {
            fields.push(rawFields[j]);
          }
        }
      }
      result.push(new SyncConflict(row.key, row.kind, fields));
    }
    return result;
  } catch (err) {
    return [];
  }
}

/** 设置页展示用的同步状态快照。 */
export class SyncStatus {
  readonly enabled: boolean;
  readonly wifiOnly: boolean;
  readonly lastSyncAt: number;
  readonly pending: number;
  readonly records: number;
  /** 上次同步自动合并的条数（0 = 没发生冲突）。 */
  readonly conflicts: number;
  readonly backend: string;
  /** 选了云同步目标时：最近一次登记或手动拉取是否成功。 */
  readonly cloudAvailable: boolean;
  /** 不可用原因（CloudAvailability 的字符串值）。 */
  readonly cloudReason: string;
  /** 系统返回的原始错误码；0 表示当前没有错误。 */
  readonly cloudErrorCode: number;
  /** 上次冲突的概要（最多 SyncLimits.CONFLICT_DETAILS 条）。 */
  readonly conflictItems: SyncConflict[];

  constructor(enabled: boolean, wifiOnly: boolean, lastAt: number, pending: number, records: number,
    conflicts: number, backend: string, cloudAvailable: boolean = true, cloudReason: string = '',
    conflictItems: SyncConflict[] = [], cloudErrorCode: number = 0) {
    this.enabled = enabled;
    this.wifiOnly = wifiOnly;
    this.lastSyncAt = lastAt;
    this.pending = pending;
    this.records = records;
    this.conflicts = conflicts;
    this.backend = backend;
    this.cloudAvailable = cloudAvailable;
    this.cloudReason = cloudReason;
    this.cloudErrorCode = cloudErrorCode;
    this.conflictItems = conflictItems;
  }
}

export class SyncService {
  /** 当前同步目标名称（第一批只有本机模拟）。 */
  readonly backendName: string = 'Mock';
  private store: preferences.Preferences | undefined = undefined;
  private syncingFlag: boolean = false;
  /** 上次自动同步尝试时间（只存内存：进程重启后允许立刻同步一次）。 */
  private lastAttemptAt: number = 0;
  /** 失败重试定时器与已重试次数。 */
  private retryTimer: number = -1;
  private retryAttempt: number = 0;
  /** 云端变更监听是否已绑定（同账号其他设备写入时触发一次自动同步）。 */
  private cloudListenerBound: boolean = false;
  /** 状态变化订阅者（设置页实时刷新用；只存内存）。 */
  private statusListeners: Array<() => void> = [];

  private async open(context: common.Context): Promise<preferences.Preferences | undefined> {
    const opened: preferences.Preferences | undefined = this.store;
    if (opened !== undefined) {
      return opened;
    }
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      this.store = store;
      return store;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'open preferences failed: %{public}d', error.code);
      return undefined;
    }
  }

  private readBoolean(store: preferences.Preferences, key: string): boolean {
    const raw: preferences.ValueType = store.getSync(key, false);
    return typeof raw === 'boolean' ? raw : false;
  }

  private readNumber(store: preferences.Preferences, key: string): number {
    const raw: preferences.ValueType = store.getSync(key, 0);
    return typeof raw === 'number' && Number.isFinite(raw) && raw > 0 ? raw : 0;
  }

  /** 节点 id：首次使用时生成，用于冲突平局时收敛（不进同步数据本身）。 */
  private async nodeId(context: common.Context): Promise<string> {
    const store: preferences.Preferences | undefined = await this.open(context);
    if (store === undefined) {
      return 'local';
    }
    const raw: preferences.ValueType = store.getSync(PreferencesConstants.KEY_CLOUD_SYNC_NODE_ID, '');
    const existing: string = typeof raw === 'string' ? raw : '';
    if (existing.length > 0) {
      return existing;
    }
    const generated: string = Date.now().toString(36) + '-' +
      Math.floor(Math.random() * 0xFFFFFF).toString(36);
    try {
      store.putSync(PreferencesConstants.KEY_CLOUD_SYNC_NODE_ID, generated);
      await store.flush();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'persist node id failed: %{public}d', error.code);
    }
    return generated;
  }

  async isEnabled(context: common.Context): Promise<boolean> {
    const store: preferences.Preferences | undefined = await this.open(context);
    return store !== undefined && this.readBoolean(store, PreferencesConstants.KEY_CLOUD_SYNC_ENABLED);
  }

  async setEnabled(context: common.Context, enabled: boolean): Promise<void> {
    const store: preferences.Preferences | undefined = await this.open(context);
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(PreferencesConstants.KEY_CLOUD_SYNC_ENABLED, enabled);
      await store.flush();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'persist switch failed: %{public}d', error.code);
    }
    if (!enabled) {
      // 关掉同步后不再重试：定时器留在那里只会在后台空转。
      this.retryAttempt = 0;
      this.clearRetryTimer();
    }
  }

  /** 仅 Wi-Fi 同步（默认开；自动触发与系统端云传输均遵守）。 */
  private readWifiOnly(store: preferences.Preferences): boolean {
    const raw: preferences.ValueType =
      store.getSync(PreferencesConstants.KEY_CLOUD_SYNC_WIFI_ONLY, true);
    return typeof raw === 'boolean' ? raw : true;
  }

  async isWifiOnly(context: common.Context): Promise<boolean> {
    const store: preferences.Preferences | undefined = await this.open(context);
    return store !== undefined ? this.readWifiOnly(store) : true;
  }

  async setWifiOnly(context: common.Context, value: boolean): Promise<void> {
    const store: preferences.Preferences | undefined = await this.open(context);
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(PreferencesConstants.KEY_CLOUD_SYNC_WIFI_ONLY, value);
      await store.flush();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'persist wifi only failed: %{public}d', error.code);
    }
  }

  private async lastSyncAt(context: common.Context): Promise<number> {
    const store: preferences.Preferences | undefined = await this.open(context);
    return store !== undefined ? this.readNumber(store, PreferencesConstants.KEY_CLOUD_SYNC_LAST_AT) : 0;
  }

  /** 订阅同步状态变化（设置页据此实时刷新时间 / 条数）。 */
  subscribeStatus(listener: () => void): void {
    if (this.statusListeners.indexOf(listener) < 0) {
      this.statusListeners.push(listener);
    }
  }

  unsubscribeStatus(listener: () => void): void {
    const index: number = this.statusListeners.indexOf(listener);
    if (index >= 0) {
      this.statusListeners.splice(index, 1);
    }
  }

  private notifyStatus(): void {
    for (let i = 0; i < this.statusListeners.length; i += 1) {
      try {
        this.statusListeners[i]();
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'status listener failed: %{public}d', error.code);
      }
    }
  }

  /** 同步目标：'mock'（本机模拟，默认）或 'cloud'（华为云空间）。 */
  private async backendKind(context: common.Context): Promise<string> {
    const store: preferences.Preferences | undefined = await this.open(context);
    if (store === undefined) {
      return 'mock';
    }
    const raw: preferences.ValueType = store.getSync(PreferencesConstants.KEY_CLOUD_SYNC_BACKEND, 'mock');
    return typeof raw === 'string' && raw === 'cloud' ? 'cloud' : 'mock';
  }

  async isCloudBackend(context: common.Context): Promise<boolean> {
    return await this.backendKind(context) === 'cloud';
  }

  /** 切换同步目标；切到云端时顺带准备云库与网络策略。 */
  async setCloudBackend(context: common.Context, cloud: boolean): Promise<void> {
    const store: preferences.Preferences | undefined = await this.open(context);
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(PreferencesConstants.KEY_CLOUD_SYNC_BACKEND, cloud ? 'cloud' : 'mock');
      await store.flush();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'persist backend failed: %{public}d', error.code);
    }
    if (cloud) {
      await this.prepareCloud(context);
    }
  }

  /**
   * 准备端云同步：打开云库 → 按「仅 Wi-Fi」设置网络策略 → 订阅云端变更。
   * 只有真正登记为分布式表才算「可用」；登记失败时返回 false，
   * 调用方据此报「cloud unavailable」，不能把本机云表当成同步成功。
   */
  private async prepareCloud(context: common.Context): Promise<boolean> {
    const opened: boolean = await cloudStore.open(context);
    if (!opened) {
      return false;
    }
    await cloudStore.setWifiOnly(await this.isWifiOnly(context));
    const ready: boolean = cloudStore.isDistributed() || await cloudStore.refresh();
    if (!ready) {
      hilog.info(DOMAIN, TAG, 'cloud unavailable: %{public}s', cloudStore.availability());
      return false;
    }
    this.bindCloudListener(context);
    return true;
  }

  /** 云端变更（同账号其他设备写入）→ 触发一次自动同步把状态合并回本地。 */
  private bindCloudListener(context: common.Context): void {
    if (this.cloudListenerBound) {
      return;
    }
    this.cloudListenerBound = true;
    cloudStore.subscribe(() => {
      this.autoSync(context, 'cloud-change').catch((err: Error) => {
        hilog.info(DOMAIN, TAG, 'cloud change sync failed: %{public}s', err.message);
      });
    });
  }

  /** 当前状态快照（设置页进入时读一次）。 */
  async status(context: common.Context): Promise<SyncStatus> {
    const store: preferences.Preferences | undefined = await this.open(context);
    const enabled: boolean = store !== undefined
      ? this.readBoolean(store, PreferencesConstants.KEY_CLOUD_SYNC_ENABLED) : false;
    const lastAt: number = store !== undefined
      ? this.readNumber(store, PreferencesConstants.KEY_CLOUD_SYNC_LAST_AT) : 0;
    const wifiOnly: boolean = store !== undefined ? this.readWifiOnly(store) : true;
    await articleDatabase.whenReady();
    const pending: number = await syncStore.pendingCount();
    const records: number = await syncStore.recordCount();
    const conflicts: number = store !== undefined
      ? this.readNumber(store, PreferencesConstants.KEY_CLOUD_SYNC_LAST_CONFLICTS) : 0;
    const details: SyncConflict[] = store !== undefined
      ? this.readConflictDetails(store) : [];
    const cloud: boolean = await this.isCloudBackend(context);
    let available: boolean = true;
    let reason: string = '';
    let errorCode: number = 0;
    if (cloud) {
      // 还没准备过云库时先试一次：设置页要能直接说清「为什么没同步」。
      const opened: boolean = await cloudStore.open(context);
      if (opened) {
        await cloudStore.refresh();
      }
      available = opened && cloudStore.availability() === CloudAvailability.READY;
      reason = available ? CloudAvailability.READY : cloudStore.availability();
      errorCode = available ? 0 : cloudStore.errorCode();
    }
    return new SyncStatus(enabled, wifiOnly, lastAt, pending, records, conflicts,
      cloud ? 'Cloud' : this.backendName, available, reason, details, errorCode);
  }

  /** 立即同步：采集 → 拉取 / 合并 / 推送 → 回写。失败不抛，返回带 error 的摘要。 */
  async syncNow(context: common.Context): Promise<SyncSummary> {
    if (this.syncingFlag) {
      return new SyncSummary(0, 0, 0, 0, 0, 'busy');
    }
    this.syncingFlag = true;
    const startedAt: number = Date.now();
    let collectMs: number = 0;
    let transferMs: number = 0;
    let applyMs: number = 0;
    try {
      await articleDatabase.whenReady();
      const origin: string = await this.nodeId(context);
      const collector: SyncCollector = new SyncCollector(syncStore, origin);
      const collectStarted: number = Date.now();
      await collector.collect(context, Date.now());
      collectMs = Date.now() - collectStarted;
      let backend: SyncBackend;
      if (await this.isCloudBackend(context)) {
        const ready: boolean = await this.prepareCloud(context);
        if (!ready) {
          return new SyncSummary(0, 0, 0, await syncStore.pendingCount(), 0, 'cloud unavailable');
        }
        // 先把云端的最新行拉到本地表，再交给引擎合并（autoSync 之外需要一次手动拉取）。
        const pulledFromCloud: boolean = await cloudStore.syncNow();
        if (!pulledFromCloud) {
          // 系统没拉起来（能力刚被关闭 / 账号被登出）：宁可报错，也不要给用户一个假的成功。
          return new SyncSummary(0, 0, 0, await syncStore.pendingCount(), 0, 'cloud unavailable');
        }
        backend = new CloudRelayBackend(cloudStore);
      } else {
        backend = new MockSyncBackend(context);
      }
      const engine: SyncEngine = new SyncEngine(backend, syncStore, origin);
      const transferStarted: number = Date.now();
      const summary: SyncSummary = await engine.run();
      transferMs = Date.now() - transferStarted;
      if (summary.error.length === 0) {
        const applyStarted: number = Date.now();
        await collector.apply(context);
        applyMs = Date.now() - applyStarted;
        await this.rememberLastSync(context, summary.at);
        await this.rememberConflicts(context, summary.conflicts, engine.conflictDetails());
        // 已推送的旧墓碑按保留期清理，避免云表随删除操作无限增长。
        const pruned: number = await syncStore.pruneTombstones(Date.now());
        if (pruned > 0) {
          hilog.info(DOMAIN, TAG, 'pruned %{public}d expired tombstones', pruned);
        }
        this.notifyStatus();
        // 这一轮成功了：清掉失败重试，避免继续在后台补试。
        this.retryAttempt = 0;
        this.clearRetryTimer();
      }
      return summary;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'sync failed: %{public}d', error.code);
      return new SyncSummary(0, 0, 0, await syncStore.pendingCount(), 0, 'unknown');
    } finally {
      this.syncingFlag = false;
      hilog.info(DOMAIN, TAG, 'perf sync total=%{public}dms collect=%{public}dms transfer=%{public}dms apply=%{public}dms',
        Date.now() - startedAt, collectMs, transferMs, applyMs);
    }
  }

  /**
   * 自动同步：冷启动 / 回前台 / 抓取完成共用。
   *
   * 静默跳过的情况：开关关闭、正在同步、仅 Wi-Fi 模式下当前不是 Wi-Fi、
   * 距上次成功同步 / 上次尝试不足最小间隔（除非是失败重试）。
   *
   * @param throttle false = 失败重试，绕过最小间隔
   * @returns 是否真正跑完并成功（调用方据此决定要不要刷新列表）
   */
  async autoSync(context: common.Context, trigger: string, throttle: boolean = true): Promise<boolean> {
    if (this.syncingFlag) {
      return false;
    }
    if (!(await this.isEnabled(context))) {
      return false;
    }
    if (await this.isWifiOnly(context) && !NetworkStatus.isUnmetered()) {
      hilog.info(DOMAIN, TAG, 'auto sync skipped (%{public}s): not on unmetered network', trigger);
      return false;
    }
    const now: number = Date.now();
    const last: number = Math.max(this.lastAttemptAt, await this.lastSyncAt(context));
    if (!AutoSyncPolicy.isDue(last, now, throttle)) {
      return false;
    }
    this.lastAttemptAt = now;
    const summary: SyncSummary = await this.syncNow(context);
    if (summary.error.length === 0) {
      hilog.info(DOMAIN, TAG, 'auto sync done (%{public}s): pushed %{public}d, pulled %{public}d',
        trigger, summary.pushed, summary.pulled);
      return true;
    }
    if (summary.error === 'busy') {
      return false;
    }
    if (summary.error === 'cloud unavailable') {
      // 端云能力不可用时重试也是白跑（账号未登录 / 未开通），等用户在设置页处理。
      hilog.info(DOMAIN, TAG, 'auto sync skipped (%{public}s): cloud unavailable', trigger);
      return false;
    }
    hilog.info(DOMAIN, TAG, 'auto sync failed (%{public}s): %{public}s', trigger, summary.error);
    this.scheduleRetry(context);
    return false;
  }

  /**
   * 后台任务（WorkScheduler）内的一次性同步。
   *
   * 不排失败重试：扩展随时可能被系统结束，定时器不可靠，交给下一次唤醒再试。
   * 开关关闭、或开启「仅 Wi-Fi」而当前不是 Wi-Fi / 以太网时静默跳过。
   */
  async syncInBackground(context: common.Context): Promise<boolean> {
    if (this.syncingFlag) {
      return false;
    }
    if (!(await this.isEnabled(context))) {
      return false;
    }
    if (await this.isWifiOnly(context) && !NetworkStatus.isUnmetered()) {
      hilog.info(DOMAIN, TAG, 'background sync skipped: not on unmetered network');
      return false;
    }
    this.lastAttemptAt = Date.now();
    const summary: SyncSummary = await this.syncNow(context);
    if (summary.error.length === 0) {
      hilog.info(DOMAIN, TAG, 'background sync done: pushed %{public}d, pulled %{public}d',
        summary.pushed, summary.pulled);
      return true;
    }
    hilog.info(DOMAIN, TAG, 'background sync failed: %{public}s', summary.error);
    return false;
  }

  /** 失败退避重试：30s / 60s / 120s，最多三次；次数用尽交给下一次自动触发。 */
  private scheduleRetry(context: common.Context): void {
    if (this.retryTimer >= 0 || !AutoSyncPolicy.canRetry(this.retryAttempt)) {
      return;
    }
    const delay: number = AutoSyncPolicy.retryDelay(this.retryAttempt);
    this.retryAttempt += 1;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.autoSync(context, 'retry', false).catch((err: Error) => {
        hilog.info(DOMAIN, TAG, 'sync retry failed: %{public}s', err.message);
      });
    }, delay);
  }

  private clearRetryTimer(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  /** 重置模拟远端（同时清空本地同步副本与游标，下次同步重新建立基线）。 */
  async resetRemote(context: common.Context): Promise<void> {
    this.retryAttempt = 0;
    this.clearRetryTimer();
    if (await this.isCloudBackend(context)) {
      await this.prepareCloud(context);
      cloudStore.clear();
    } else {
      const backend: MockSyncBackend = new MockSyncBackend(context);
      await backend.reset();
    }
    syncStore.clearAll();
    await this.rememberLastSync(context, 0);
  }

  syncing(): boolean {
    return this.syncingFlag;
  }

  /** 记住本次自动合并条数与概要（0 也要写，避免上一次的计数一直挂在页面上）。 */
  private async rememberConflicts(context: common.Context, conflicts: number,
    details: SyncConflict[]): Promise<void> {
    const store: preferences.Preferences | undefined = await this.open(context);
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(PreferencesConstants.KEY_CLOUD_SYNC_LAST_CONFLICTS,
        conflicts > 0 ? conflicts : 0);
      store.putSync(PreferencesConstants.KEY_CLOUD_SYNC_CONFLICT_DETAILS,
        encodeConflictDetails(conflicts > 0 ? details : []));
      await store.flush();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'persist conflicts failed: %{public}d', error.code);
    }
  }

  /** 读出上次冲突概要；脏数据一律当空，不影响页面。 */
  private readConflictDetails(store: preferences.Preferences): SyncConflict[] {
    const raw: preferences.ValueType =
      store.getSync(PreferencesConstants.KEY_CLOUD_SYNC_CONFLICT_DETAILS, '');
    if (typeof raw !== 'string' || raw.length === 0) {
      return [];
    }
    return decodeConflictDetails(raw);
  }

  private async rememberLastSync(context: common.Context, at: number): Promise<void> {
    const store: preferences.Preferences | undefined = await this.open(context);
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(PreferencesConstants.KEY_CLOUD_SYNC_LAST_AT, at);
      await store.flush();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'persist last sync failed: %{public}d', error.code);
    }
  }
}

export const syncService: SyncService = new SyncService();
