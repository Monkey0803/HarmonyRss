/*
 * CloudStore.ets — 华为「云同步服务」容器里的本地镜像表。
 *
 * 这里只做两件事：
 *   1. 建本地 SQLite 库 `harmonyrss_cloud.db` 与表 `cloudSyncRecords`（字段与 AGC 容器一致）；
 *   2. 把表登记为分布式表（DISTRIBUTED_CLOUD），之后由系统在登录同一华为账号的设备之间同步行。
 *
 * 冲突语义仍是「整行后写」：行内没有字段级时间戳，字段级合并由 SyncEngine 在本地完成。
 * 所有云能力调用都处理失败：登记不成功时本地表仍可读写，应用不会把它当成云同步成功。
 */

import { relationalStore, cloudData } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SyncRecord } from '../../model/Sync';

const DOMAIN: number = 0x0000;
const TAG: string = 'CloudStore';

/** 云库文件名：与 AGC 容器 `harmonyrss_cloud` 对应。 */
const DB_NAME: string = 'harmonyrss_cloud.db';
/** 表名：必须与 AGC 数据类型 / 本地表名称一致。 */
export const CLOUD_TABLE: string = 'cloudSyncRecords';

const SQL_CREATE_TABLE: string =
  'CREATE TABLE IF NOT EXISTS ' + CLOUD_TABLE + ' (' +
  'recordKey TEXT PRIMARY KEY, ' +
  'kind TEXT NOT NULL DEFAULT \'\', ' +
  'payload TEXT NOT NULL DEFAULT \'\', ' +
  'updatedAt TEXT NOT NULL DEFAULT \'0\', ' +
  'deleted INTEGER NOT NULL DEFAULT 0, ' +
  'origin TEXT NOT NULL DEFAULT \'\')';

/** 时间戳相同时以主键续页，避免一页末尾的同毫秒记录被跳过。 */
export const CLOUD_PAGE_SQL: string =
  'SELECT recordKey, kind, payload, updatedAt, deleted, origin FROM ' + CLOUD_TABLE +
  ' WHERE CAST(updatedAt AS INTEGER) > ?' +
  ' OR (CAST(updatedAt AS INTEGER) = ? AND recordKey > ?)' +
  ' ORDER BY CAST(updatedAt AS INTEGER) ASC, recordKey ASC LIMIT ?';

/** 远端变更回调（系统通知「云端这张表变了」时调用）。 */
export type CloudChangeListener = () => void;

/** 端云同步的可用性：设置页据此说清楚「为什么没同步」。 */
export enum CloudAvailability {
  /** 已登记分布式表，可跨设备同步。 */
  READY = 'ready',
  /** 云库打不开（存储异常）。 */
  STORE_FAILED = 'storeFailed',
  /** 系统 / 设备不支持端云数据同步能力。 */
  UNSUPPORTED = 'unsupported',
  /** 这张表此前登记的分布式类型与当前请求不一致。 */
  TABLE_TYPE_MISMATCH = 'tableTypeMismatch',
  /** 系统报告云空间不可用；可能与账号或应用云开关有关。 */
  CLOUD_DISABLED = 'cloudDisabled',
  /** 系统报告网络错误。 */
  NETWORK_FAILED = 'networkFailed',
  /** 仅 Wi-Fi 策略阻止了本轮同步。 */
  WIFI_REQUIRED = 'wifiRequired',
  /** 分布式表已登记，但本次手动拉取失败。 */
  SYNC_FAILED = 'syncFailed',
  /** 系统没有给出足以区分账号、云空间开关与 AGC 配置的错误码。 */
  UNKNOWN = 'unknown'
}

/** `setDistributedTables` 在能力不支持时返回的错误码。 */
const ERR_CAPABILITY_UNSUPPORTED: number = 801;
/** SDK 声明的分布式表类型不匹配 / 数据库实例已关闭错误码。 */
const ERR_DISTRIBUTED_TYPE_MISMATCH: number = 14800051;
const ERR_STORE_CLOSED: number = 14800014;
const CLOUD_SYNC_TIMEOUT_MS: number = 60000;

/** 只把 SDK 文档明确赋义的错误码归到确定原因，其余保留为未知。 */
export function classifyCloudRegistrationError(code: number): CloudAvailability {
  if (code === ERR_CAPABILITY_UNSUPPORTED) {
    return CloudAvailability.UNSUPPORTED;
  }
  if (code === ERR_DISTRIBUTED_TYPE_MISMATCH) {
    return CloudAvailability.TABLE_TYPE_MISMATCH;
  }
  if (code === ERR_STORE_CLOSED) {
    return CloudAvailability.STORE_FAILED;
  }
  return CloudAvailability.UNKNOWN;
}

export function classifyCloudSyncError(code: number): CloudAvailability {
  return code === ERR_CAPABILITY_UNSUPPORTED
    ? CloudAvailability.UNSUPPORTED : CloudAvailability.SYNC_FAILED;
}

/** 进度回调的 code 与调用异常的 BusinessError.code 属于不同错误码空间。 */
export function classifyCloudProgressCode(code: number): CloudAvailability {
  if (code === relationalStore.ProgressCode.SUCCESS) {
    return CloudAvailability.READY;
  }
  if (code === relationalStore.ProgressCode.CLOUD_DISABLED) {
    return CloudAvailability.CLOUD_DISABLED;
  }
  if (code === relationalStore.ProgressCode.NETWORK_ERROR) {
    return CloudAvailability.NETWORK_FAILED;
  }
  if (code === relationalStore.ProgressCode.BLOCKED_BY_NETWORK_STRATEGY) {
    return CloudAvailability.WIFI_REQUIRED;
  }
  return CloudAvailability.SYNC_FAILED;
}

function recordFromRow(rs: relationalStore.ResultSet): SyncRecord {
  // 三处读取使用同一列序，分页同步时避免逐记录查六次列名。
  return new SyncRecord(
    rs.getString(0),
    rs.getString(1),
    Number(rs.getString(3)),
    rs.getLong(4) === 1,
    rs.getString(2),
    rs.getString(5));
}

export class CloudStore {
  private store: relationalStore.RdbStore | undefined = undefined;
  /** 是否已成功登记为端云分布式表（false 时只在本机读写）。 */
  private distributed: boolean = false;
  /** 最近一次可用性判定结果。 */
  private availabilityState: CloudAvailability = CloudAvailability.UNKNOWN;
  private lastErrorCode: number = 0;
  private listener: CloudChangeListener | undefined = undefined;
  private observer: ((accounts: Array<string>) => void) | undefined = undefined;

  /** 打开本地云库并尝试登记分布式表；返回是否拿到了库。 */
  async open(context: common.Context): Promise<boolean> {
    if (this.store !== undefined) {
      return true;
    }
    try {
      const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
      await store.executeSql(SQL_CREATE_TABLE);
      this.store = store;
      await this.enableDistributed(store);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'open cloud store failed: %{public}d', error.code);
      this.lastErrorCode = error.code;
      this.availabilityState = CloudAvailability.STORE_FAILED;
      return false;
    }
  }

  /** 登记端云分布式表；失败不影响本地读写。 */
  private async enableDistributed(store: relationalStore.RdbStore): Promise<void> {
    try {
      const config: relationalStore.DistributedConfig = { autoSync: true };
      await store.setDistributedTables([CLOUD_TABLE],
        relationalStore.DistributedType.DISTRIBUTED_CLOUD, config);
      this.distributed = true;
      this.availabilityState = CloudAvailability.READY;
      this.lastErrorCode = 0;
      hilog.info(DOMAIN, TAG, 'cloud sync enabled for %{public}s', CLOUD_TABLE);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      this.distributed = false;
      this.lastErrorCode = error.code;
      this.availabilityState = classifyCloudRegistrationError(error.code);
      hilog.warn(DOMAIN, TAG, 'setDistributedTables failed (code=%{public}d, reason=%{public}s)',
        error.code, this.availabilityState);
    }
  }

  /** 是否已接入端云同步（用于设置页状态与手动同步）。 */
  isDistributed(): boolean {
    return this.distributed;
  }

  /**
   * 重新尝试登记分布式表：用户刚登录华为账号 / 刚在 AGC 开通后不必重启应用。
   * 已可用时直接返回 true，不重复调用系统接口。
   */
  async refresh(): Promise<boolean> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return false;
    }
    if (this.distributed) {
      return true;
    }
    await this.enableDistributed(store);
    return this.distributed;
  }

  /** 最近一次登记或手动云同步的状态。 */
  availability(): CloudAvailability {
    return this.availabilityState;
  }

  /** 系统原始错误码；0 表示当前没有错误。 */
  errorCode(): number {
    return this.lastErrorCode;
  }

  /** 设置网络策略：仅 Wi-Fi 时不允许走蜂窝。 */
  async setWifiOnly(wifiOnly: boolean): Promise<void> {
    try {
      if (wifiOnly) {
        await cloudData.setCloudStrategy(cloudData.StrategyType.NETWORK,
          [cloudData.NetWorkStrategy.WIFI]);
      } else {
        await cloudData.setCloudStrategy(cloudData.StrategyType.NETWORK,
          [cloudData.NetWorkStrategy.WIFI, cloudData.NetWorkStrategy.CELLULAR]);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setCloudStrategy failed: %{public}d', error.code);
    }
  }

  /**
   * 手动触发一次端云同步（autoSync 之外，用户点「立即同步」时先拉一轮云端行）。
   * 返回是否真的拉了一轮：未登记分布式表时返回 false，调用方不能把它当成「同步成功」。
   */
  async syncNow(): Promise<boolean> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || !this.distributed) {
      return false;
    }
    let finish: (code: number) => void = (_code: number): void => {};
    const finished: Promise<number> = new Promise<number>((resolve: (code: number) => void): void => {
      finish = resolve;
    });
    let observedErrorCode: number = 0;
    const timeoutId: number = setTimeout((): void => {
      finish(observedErrorCode > 0 ? observedErrorCode : -1);
    }, CLOUD_SYNC_TIMEOUT_MS);
    try {
      await store.cloudSync(relationalStore.SyncMode.SYNC_MODE_TIME_FIRST, [CLOUD_TABLE],
        (progress: relationalStore.ProgressDetails) => {
          hilog.info(DOMAIN, TAG, 'cloud sync progress: %{public}d code=%{public}d',
            progress.schedule, progress.code);
          if (progress.code !== relationalStore.ProgressCode.SUCCESS) {
            observedErrorCode = progress.code;
          }
          if (progress.schedule === relationalStore.Progress.SYNC_FINISH) {
            const table: relationalStore.TableDetails | undefined = progress.details[CLOUD_TABLE];
            const hasIncompleteRows: boolean = table !== undefined &&
              (table.upload.failed > 0 || table.download.failed > 0 ||
                table.upload.remained > 0 || table.download.remained > 0);
            finish(hasIncompleteRows && progress.code === relationalStore.ProgressCode.SUCCESS
              ? -2 : progress.code);
          }
        });
      const code: number = await finished;
      if (code !== relationalStore.ProgressCode.SUCCESS) {
        this.lastErrorCode = code > 0 ? code : 0;
        this.availabilityState = classifyCloudProgressCode(code);
        hilog.warn(DOMAIN, TAG, 'cloudSync finished with code=%{public}d', code);
        return false;
      }
      this.availabilityState = CloudAvailability.READY;
      this.lastErrorCode = 0;
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      this.lastErrorCode = error.code;
      this.availabilityState = classifyCloudSyncError(error.code);
      hilog.warn(DOMAIN, TAG, 'cloudSync failed: %{public}d', error.code);
      return false;
    } finally {
      clearTimeout(timeoutId);
    }
  }

  /**
   * 增量读取：按 `(updatedAt, recordKey)` 严格续页，最多 limit 条。
   * 走 SQL 而不是「全表读出来再过滤」，万级记录时少了 O(n²) 的内存与比较开销。
   */
  async listSince(cursorTime: number, cursorKey: string, limit: number): Promise<SyncRecord[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: SyncRecord[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(CLOUD_PAGE_SQL,
        [cursorTime, cursorTime, cursorKey, limit]);
      try {
        while (rs.goToNextRow()) {
          result.push(recordFromRow(rs));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'listSince failed: %{public}d', error.code);
    }
    return result;
  }

  /** 全表读取（按修改时间升序，供后端按游标分页）。 */
  async listAll(): Promise<SyncRecord[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: SyncRecord[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT recordKey, kind, payload, updatedAt, deleted, origin FROM ' + CLOUD_TABLE +
        ' ORDER BY CAST(updatedAt AS INTEGER) ASC, recordKey ASC');
      try {
        while (rs.goToNextRow()) {
          result.push(recordFromRow(rs));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'listAll failed: %{public}d', error.code);
    }
    return result;
  }

  /** 按主键读一条；不存在返回 undefined。 */
  async find(key: string): Promise<SyncRecord | undefined> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || key.length === 0) {
      return undefined;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT recordKey, kind, payload, updatedAt, deleted, origin FROM ' + CLOUD_TABLE +
        ' WHERE recordKey = ?', [key]);
      try {
        if (rs.goToNextRow()) {
          return recordFromRow(rs);
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'find failed: %{public}d', error.code);
    }
    return undefined;
  }

  /** 写入 / 覆盖一条记录（系统据此自动上云）。 */
  upsert(record: SyncRecord): boolean {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return false;
    }
    try {
      store.executeSync('INSERT OR REPLACE INTO ' + CLOUD_TABLE +
        ' (recordKey, kind, payload, updatedAt, deleted, origin) VALUES (?, ?, ?, ?, ?, ?)',
        [record.key, record.kind, record.payload, record.updatedAt.toString(),
          record.deleted ? 1 : 0, record.origin]);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'upsert failed: %{public}d', error.code);
      return false;
    }
  }

  /** 清空（仅调试 / 重置用，会同步删除云端行）。 */
  clear(): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync('DELETE FROM ' + CLOUD_TABLE);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'clear failed: %{public}d', error.code);
    }
  }

  /** 订阅云端变更（同账号其他设备的写入）；重复调用覆盖旧监听。 */
  subscribe(listener: CloudChangeListener): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || this.observer !== undefined) {
      this.listener = listener;
      return;
    }
    this.listener = listener;
    const observer = (accounts: Array<string>): void => {
      hilog.info(DOMAIN, TAG, 'cloud data changed: %{public}d account(s)', accounts.length);
      const callback: CloudChangeListener | undefined = this.listener;
      if (callback !== undefined) {
        callback();
      }
    };
    try {
      store.on('dataChange', relationalStore.SubscribeType.SUBSCRIBE_TYPE_CLOUD, observer);
      this.observer = observer;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'subscribe failed: %{public}d', error.code);
    }
  }

  /** 退订云端变更。 */
  unsubscribe(): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    const observer: ((accounts: Array<string>) => void) | undefined = this.observer;
    this.listener = undefined;
    this.observer = undefined;
    if (store === undefined || observer === undefined) {
      return;
    }
    try {
      store.off('dataChange', relationalStore.SubscribeType.SUBSCRIBE_TYPE_CLOUD, observer);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'unsubscribe failed: %{public}d', error.code);
    }
  }
}

export const cloudStore: CloudStore = new CloudStore();
