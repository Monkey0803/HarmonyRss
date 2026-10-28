/*
 * SyncStore.ets — 云同步记录表的读写（Model 层：屏蔽 SQL）。
 *
 * 复用 ArticleStore 打开的同一个 RdbStore（同进程不重复打开同名库）。
 * 一行 = 一个实体的本地副本：
 *   - dirty = 1：本地改过、待推送；
 *   - rev：已经拉到的远端版本（只作诊断，不做比较）；
 *   - deleted = 1：墓碑，删除同样要同步出去。
 *
 * 游标 / 上次同步时间复用已有的 sync_state 表（key → value）。
 */

import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ArticleDbConstants } from '../../common/constants/RssConstants';
import { SyncKinds, SyncRecord } from '../../model/Sync';
import { articleStore } from '../ArticleStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'SyncStore';

/** 同步表里的游标键（与远端账号同步用的 key 区分开）。 */
export const SYNC_CURSOR_KEY: string = 'cloud_sync_cursor';

/** 同步记录上限：防止异常数据把库撑爆（正常量级是订阅数 + 文章数）。 */
export class SyncLimits {
  static readonly PUSH_BATCH: number = 200;
  static readonly PULL_BATCH: number = 200;
  /** 单次同步最多拉取页数，避免后端游标异常时死循环。 */
  static readonly MAX_PULL_PAGES: number = 50;
}

function recordFromRow(rs: relationalStore.ResultSet): SyncRecord {
  return new SyncRecord(
    rs.getString(rs.getColumnIndex('key')),
    rs.getString(rs.getColumnIndex('kind')),
    rs.getLong(rs.getColumnIndex('updated_at')),
    rs.getLong(rs.getColumnIndex('deleted')) === 1,
    rs.getString(rs.getColumnIndex('payload')),
    rs.getString(rs.getColumnIndex('origin')));
}


/**
 * 同步记录存储的端口（引擎只依赖这组方法）。
 * 生产实现是 SyncStore（RDB），单测用内存实现，避免起数据库。
 */
export interface SyncRecordStore {
  listByKind(kind: string): Promise<SyncRecord[]>;
  find(key: string): Promise<SyncRecord | undefined>;
  listDirty(limit: number): Promise<SyncRecord[]>;
  upsert(record: SyncRecord, dirty: boolean, rev?: string): void;
  markClean(keys: string[]): void;
  pendingCount(): Promise<number>;
  recordCount(): Promise<number>;
  getCursor(): Promise<string>;
  setCursor(cursor: string): void;
  clearAll(): void;
}

export class SyncStore implements SyncRecordStore {
  /** 同步表是否可用（库没打开时返回空态，不抛错）。 */
  private db(): relationalStore.RdbStore | undefined {
    return articleStore.getStore();
  }

  /** 读某一类记录（差量采集时与当前快照比对）。 */
  async listByKind(kind: string): Promise<SyncRecord[]> {
    const result: SyncRecord[] = [];
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT key, kind, updated_at, deleted, payload, origin FROM ' +
        ArticleDbConstants.TABLE_SYNC_RECORDS + ' WHERE kind = ?', [kind]);
      try {
        while (rs.goToNextRow()) {
          result.push(recordFromRow(rs));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'listByKind failed: %{public}d', error.code);
    }
    return result;
  }

  /** 按 key 读单条（不存在返回 undefined）。 */
  async find(key: string): Promise<SyncRecord | undefined> {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined || key.length === 0) {
      return undefined;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT key, kind, updated_at, deleted, payload, origin FROM ' +
        ArticleDbConstants.TABLE_SYNC_RECORDS + ' WHERE key = ?', [key]);
      try {
        if (rs.goToNextRow()) {
          return recordFromRow(rs);
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'find failed: %{public}d', error.code);
    }
    return undefined;
  }

  /** 待推送记录（按修改时间升序，先改先推）。 */
  async listDirty(limit: number): Promise<SyncRecord[]> {
    const result: SyncRecord[] = [];
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT key, kind, updated_at, deleted, payload, origin FROM ' +
        ArticleDbConstants.TABLE_SYNC_RECORDS +
        ' WHERE dirty = 1 ORDER BY updated_at ASC LIMIT ?', [limit]);
      try {
        while (rs.goToNextRow()) {
          result.push(recordFromRow(rs));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'listDirty failed: %{public}d', error.code);
    }
    return result;
  }

  /** 写入 / 覆盖一条记录（dirty 决定是否需要推送）。 */
  upsert(record: SyncRecord, dirty: boolean, rev: string = ''): void {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return;
    }
    this.exec('INSERT OR REPLACE INTO ' + ArticleDbConstants.TABLE_SYNC_RECORDS +
      ' (key, kind, payload, updated_at, deleted, dirty, origin, rev)' +
      ' VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [record.key, record.kind, record.payload, record.updatedAt,
        record.deleted ? 1 : 0, dirty ? 1 : 0, record.origin, rev]);
  }

  /** 推送成功后标干净（失败重试时才需要）。 */
  markClean(keys: string[]): void {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined || keys.length === 0) {
      return;
    }
    for (let i = 0; i < keys.length; i += 1) {
      this.exec('UPDATE ' + ArticleDbConstants.TABLE_SYNC_RECORDS + ' SET dirty = 0 WHERE key = ?',
        [keys[i]]);
    }
  }

  /** 待推送条数（设置页展示）。 */
  async pendingCount(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_SYNC_RECORDS + ' WHERE dirty = 1');
      try {
        if (rs.goToNextRow()) {
          return rs.getLong(rs.getColumnIndex('c'));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'pendingCount failed: %{public}d', error.code);
    }
    return 0;
  }

  /** 已同步实体条数（不含墓碑）。 */
  async recordCount(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_SYNC_RECORDS + ' WHERE deleted = 0');
      try {
        if (rs.goToNextRow()) {
          return rs.getLong(rs.getColumnIndex('c'));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'recordCount failed: %{public}d', error.code);
    }
    return 0;
  }

  /** 读游标（空串 = 首次同步）。 */
  async getCursor(): Promise<string> {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return '';
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT value FROM ' + ArticleDbConstants.TABLE_SYNC_STATE + ' WHERE key = ?',
        [SYNC_CURSOR_KEY]);
      try {
        if (rs.goToNextRow()) {
          return rs.getString(rs.getColumnIndex('value'));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getCursor failed: %{public}d', error.code);
    }
    return '';
  }

  setCursor(cursor: string): void {
    this.exec('INSERT OR REPLACE INTO ' + ArticleDbConstants.TABLE_SYNC_STATE +
      ' (key, value) VALUES (?, ?)', [SYNC_CURSOR_KEY, cursor]);
  }

  /** 清空本地同步副本（重置 / 换账号时用；不影响文章与订阅本身）。 */
  clearAll(): void {
    this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_SYNC_RECORDS, []);
    this.setCursor('');
  }

  private exec(sql: string, args: relationalStore.ValueType[]): void {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync(sql, args);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'exec failed: %{public}d', error.code);
    }
  }
}

export const syncStore: SyncStore = new SyncStore();

/** 实体类型是否受支持（差量采集与合并只处理这些类型）。 */
export function isSyncableKind(kind: string): boolean {
  return kind === SyncKinds.FEED || kind === SyncKinds.ARTICLE_STATE ||
    kind === SyncKinds.HIGHLIGHT || kind === SyncKinds.TAG ||
    kind === SyncKinds.ARTICLE_TAG || kind === SyncKinds.SETTINGS ||
    kind === SyncKinds.SMART_FOLDER || kind === SyncKinds.RULE ||
    kind === SyncKinds.TEMPLATE;
}
