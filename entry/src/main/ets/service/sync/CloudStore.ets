/*
 * CloudStore.ets — 华为「云同步服务」容器里的本地镜像表。
 *
 * 这里只做两件事：
 *   1. 建本地 SQLite 库 `harmonyrss_cloud.db` 与表 `cloudSyncRecords`（字段与 AGC 容器一致）；
 *   2. 把表登记为分布式表（DISTRIBUTED_CLOUD），之后由系统在登录同一华为账号的设备之间同步行。
 *
 * 冲突语义仍是「整行后写」：行内没有字段级时间戳，字段级合并由 SyncEngine 在本地完成。
 * 所有云能力调用都 try/catch：未在 AGC 部署 / 未登录华为账号时降级为「本地表可读写、不上云」。
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

/** 远端变更回调（系统通知「云端这张表变了」时调用）。 */
export type CloudChangeListener = () => void;

function recordFromRow(rs: relationalStore.ResultSet): SyncRecord {
  return new SyncRecord(
    rs.getString(rs.getColumnIndex('recordKey')),
    rs.getString(rs.getColumnIndex('kind')),
    Number(rs.getString(rs.getColumnIndex('updatedAt'))),
    rs.getLong(rs.getColumnIndex('deleted')) === 1,
    rs.getString(rs.getColumnIndex('payload')),
    rs.getString(rs.getColumnIndex('origin')));
}

export class CloudStore {
  private store: relationalStore.RdbStore | undefined = undefined;
  /** 是否已成功登记为端云分布式表（false 时只在本机读写）。 */
  private distributed: boolean = false;
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
      return false;
    }
  }

  /** 登记端云分布式表；未在 AGC 部署时这里会失败，但不影响本地读写。 */
  private async enableDistributed(store: relationalStore.RdbStore): Promise<void> {
    try {
      const config: relationalStore.DistributedConfig = { autoSync: true };
      await store.setDistributedTables([CLOUD_TABLE],
        relationalStore.DistributedType.DISTRIBUTED_CLOUD, config);
      this.distributed = true;
      hilog.info(DOMAIN, TAG, 'cloud sync enabled for %{public}s', CLOUD_TABLE);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      this.distributed = false;
      hilog.warn(DOMAIN, TAG, 'setDistributedTables failed (cloud not configured?): %{public}d',
        error.code);
    }
  }

  /** 是否已接入端云同步（用于设置页状态与手动同步）。 */
  isDistributed(): boolean {
    return this.distributed;
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

  /** 手动触发一次端云同步（autoSync 之外，用户点「立即同步」时先拉一轮云端行）。 */
  async syncNow(): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || !this.distributed) {
      return;
    }
    try {
      await store.cloudSync(relationalStore.SyncMode.SYNC_MODE_TIME_FIRST, [CLOUD_TABLE],
        (progress: relationalStore.ProgressDetails) => {
          hilog.info(DOMAIN, TAG, 'cloud sync progress: %{public}d', progress.schedule);
        });
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cloudSync failed: %{public}d', error.code);
    }
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
        ' ORDER BY CAST(updatedAt AS INTEGER) ASC');
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
