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
import { SyncSummary } from '../model/Sync';
import { articleStore } from './ArticleStore';
import { NetworkStatus } from './NetworkStatus';
import { AutoSyncPolicy } from './sync/AutoSyncPolicy';
import { SyncCollector } from './sync/SyncCollector';
import { SyncEngine } from './sync/SyncEngine';
import { syncStore } from './sync/SyncStore';
import { MockSyncBackend } from './sync/MockSyncBackend';
import { cloudStore } from './sync/CloudStore';
import { CloudRelayBackend } from './sync/CloudRelayBackend';
import { SyncBackend } from './sync/SyncBackend';

const DOMAIN: number = 0x0000;
const TAG: string = 'SyncService';

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

  constructor(enabled: boolean, wifiOnly: boolean, lastAt: number, pending: number, records: number,
    conflicts: number, backend: string) {
    this.enabled = enabled;
    this.wifiOnly = wifiOnly;
    this.lastSyncAt = lastAt;
    this.pending = pending;
    this.records = records;
    this.conflicts = conflicts;
    this.backend = backend;
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

  /** 仅 Wi-Fi 同步（默认开；只约束自动同步，手动「立即同步」由用户自己决定）。 */
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
   * AGC 未部署 / 未登录华为账号时 open 仍会成功（只是没登记分布式表），此时同步退化为本机表。
   */
  private async prepareCloud(context: common.Context): Promise<boolean> {
    const opened: boolean = await cloudStore.open(context);
    if (!opened) {
      return false;
    }
    await cloudStore.setWifiOnly(await this.isWifiOnly(context));
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
    await articleStore.whenReady();
    const pending: number = await syncStore.pendingCount();
    const records: number = await syncStore.recordCount();
    const conflicts: number = store !== undefined
      ? this.readNumber(store, PreferencesConstants.KEY_CLOUD_SYNC_LAST_CONFLICTS) : 0;
    const cloud: boolean = await this.isCloudBackend(context);
    return new SyncStatus(enabled, wifiOnly, lastAt, pending, records, conflicts,
      cloud ? 'Cloud' : this.backendName);
  }

  /** 立即同步：采集 → 拉取 / 合并 / 推送 → 回写。失败不抛，返回带 error 的摘要。 */
  async syncNow(context: common.Context): Promise<SyncSummary> {
    if (this.syncingFlag) {
      return new SyncSummary(0, 0, 0, 0, 0, 'busy');
    }
    this.syncingFlag = true;
    try {
      await articleStore.whenReady();
      const origin: string = await this.nodeId(context);
      const collector: SyncCollector = new SyncCollector(syncStore, origin);
      await collector.collect(context, Date.now());
      let backend: SyncBackend;
      if (await this.isCloudBackend(context)) {
        const ready: boolean = await this.prepareCloud(context);
        if (!ready) {
          return new SyncSummary(0, 0, 0, await syncStore.pendingCount(), 0, 'cloud unavailable');
        }
        // 先把云端的最新行拉到本地表，再交给引擎合并（autoSync 之外需要一次手动拉取）。
        await cloudStore.syncNow();
        backend = new CloudRelayBackend(cloudStore);
      } else {
        backend = new MockSyncBackend(context);
      }
      const engine: SyncEngine = new SyncEngine(backend, syncStore, origin);
      const summary: SyncSummary = await engine.run();
      if (summary.error.length === 0) {
        await collector.apply(context);
        await this.rememberLastSync(context, summary.at);
        await this.rememberConflicts(context, summary.conflicts);
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

  /** 记住本次自动合并条数（0 也要写，避免上一次的计数一直挂在页面上）。 */
  private async rememberConflicts(context: common.Context, conflicts: number): Promise<void> {
    const store: preferences.Preferences | undefined = await this.open(context);
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(PreferencesConstants.KEY_CLOUD_SYNC_LAST_CONFLICTS,
        conflicts > 0 ? conflicts : 0);
      await store.flush();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'persist conflicts failed: %{public}d', error.code);
    }
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
