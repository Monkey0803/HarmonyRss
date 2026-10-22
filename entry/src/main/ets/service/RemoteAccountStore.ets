/*
 * RemoteAccountStore.ets — 远端账号 / 同步游标 / 文章映射 / 待同步队列的 SQL 层。
 *
 * 复用 ArticleStore 打开的同一个 RDB 连接（getStore），不重复打开数据库。
 * 所有失败只记日志并返回空态：远端同步是增强能力，不能影响本地阅读。
 */

import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ArticleDbConstants } from '../common/constants/RssConstants';
import { OutboxItem, RemoteAccount, RemoteMapping } from '../model/Remote';
import { articleStore } from './ArticleStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'RemoteAccountStore';

/** 生成 IN (?,?,…) 占位符。 */
function placeholders(count: number): string {
  const parts: string[] = [];
  for (let i = 0; i < count; i += 1) {
    parts.push('?');
  }
  return parts.join(',');
}

export class RemoteAccountStore {
  private db(): relationalStore.RdbStore | undefined {
    return articleStore.getStore();
  }

  /** 读单账号（多条时取最近更新的一条）。 */
  async loadAccount(): Promise<RemoteAccount | undefined> {
    await articleStore.whenReady();
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return undefined;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id, base_url, username, service_type, enabled, created_at, updated_at,' +
        ' last_sync_at, failure_count, last_error FROM ' + ArticleDbConstants.TABLE_REMOTE_ACCOUNTS +
        ' ORDER BY updated_at DESC LIMIT 1');
      try {
        if (!rs.goToNextRow()) {
          return undefined;
        }
        const account: RemoteAccount = new RemoteAccount(
          rs.getString(rs.getColumnIndex('id')),
          rs.getString(rs.getColumnIndex('base_url')),
          rs.getString(rs.getColumnIndex('username')),
          rs.getString(rs.getColumnIndex('service_type')));
        account.enabled = rs.getLong(rs.getColumnIndex('enabled')) === 1;
        account.createdAt = rs.getLong(rs.getColumnIndex('created_at'));
        account.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
        account.lastSyncAt = rs.getLong(rs.getColumnIndex('last_sync_at'));
        account.failureCount = rs.getLong(rs.getColumnIndex('failure_count'));
        account.lastError = rs.getString(rs.getColumnIndex('last_error'));
        return account;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'loadAccount failed: %{public}d', error.code);
      return undefined;
    }
  }

  /** 保存账号（单账号：先清空再写，避免历史脏数据残留）。 */
  async saveAccount(account: RemoteAccount): Promise<void> {
    await articleStore.whenReady();
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return;
    }
    account.updatedAt = Date.now();
    try {
      store.beginTransaction();
      try {
        store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_REMOTE_ACCOUNTS);
        store.executeSync('INSERT OR REPLACE INTO ' + ArticleDbConstants.TABLE_REMOTE_ACCOUNTS +
          ' (id, base_url, username, service_type, enabled, created_at, updated_at,' +
          ' last_sync_at, failure_count, last_error) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [account.id, account.baseUrl, account.username, account.serviceType,
            account.enabled ? 1 : 0, account.createdAt, account.updatedAt,
            account.lastSyncAt, account.failureCount, account.lastError]);
        store.commit();
      } catch (inner) {
        store.rollBack();
        throw inner as Error;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'saveAccount failed: %{public}d', error.code);
    }
  }

  /** 清空账号（退出登录）。 */
  async clearAccount(): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_REMOTE_ACCOUNTS);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'clearAccount failed: %{public}d', error.code);
    }
  }

  /** 读一个同步状态值（不存在返回空串）。 */
  async getState(key: string): Promise<string> {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return '';
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT value FROM ' + ArticleDbConstants.TABLE_SYNC_STATE + ' WHERE key = ?', [key]);
      try {
        return rs.goToNextRow() ? rs.getString(rs.getColumnIndex('value')) : '';
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getState failed: %{public}d', error.code);
      return '';
    }
  }

  /** 写一个同步状态值。 */
  async setState(key: string, value: string): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync('INSERT OR REPLACE INTO ' + ArticleDbConstants.TABLE_SYNC_STATE +
        ' (key, value) VALUES (?, ?)', [key, value]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setState failed: %{public}d', error.code);
    }
  }

  /** 记录远端 id → 本地文章 id 的映射。 */
  mapRemote(remoteId: string, articleId: string, feedId: string): void {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync('INSERT OR REPLACE INTO ' + ArticleDbConstants.TABLE_REMOTE_ARTICLE_MAP +
        ' (remote_id, article_id, feed_id, updated_at) VALUES (?, ?, ?, ?)',
        [remoteId, articleId, feedId, Date.now()]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'mapRemote failed: %{public}d', error.code);
    }
  }

  /** 远端 id → 本地文章 id。 */
  async articleIdOf(remoteId: string): Promise<string | undefined> {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return undefined;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT article_id FROM ' + ArticleDbConstants.TABLE_REMOTE_ARTICLE_MAP +
        ' WHERE remote_id = ?', [remoteId]);
      try {
        return rs.goToNextRow() ? rs.getString(rs.getColumnIndex('article_id')) : undefined;
      } finally {
        rs.close();
      }
    } catch (err) {
      return undefined;
    }
  }

  /** 本地文章 id → 远端 id（回写状态用）。 */
  async remoteIdOf(articleId: string): Promise<string | undefined> {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return undefined;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT remote_id FROM ' + ArticleDbConstants.TABLE_REMOTE_ARTICLE_MAP +
        ' WHERE article_id = ? LIMIT 1', [articleId]);
      try {
        return rs.goToNextRow() ? rs.getString(rs.getColumnIndex('remote_id')) : undefined;
      } finally {
        rs.close();
      }
    } catch (err) {
      return undefined;
    }
  }

  /** 全部映射（同步开始时一次读出，避免逐篇查询）。 */
  async allMappings(): Promise<RemoteMapping[]> {
    const store: relationalStore.RdbStore | undefined = this.db();
    const result: RemoteMapping[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT remote_id, article_id, feed_id FROM ' +
        ArticleDbConstants.TABLE_REMOTE_ARTICLE_MAP);
      try {
        while (rs.goToNextRow()) {
          result.push(new RemoteMapping(
            rs.getString(rs.getColumnIndex('remote_id')),
            rs.getString(rs.getColumnIndex('article_id')),
            rs.getString(rs.getColumnIndex('feed_id'))));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'allMappings failed: %{public}d', error.code);
    }
    return result;
  }

  /**
   * 本地状态变更入队（同篇聚合）：只覆盖传进来的字段，另一字段保持原值。
   * read / starred 传 undefined 表示「不改这个字段」。
   *
   * 同步实现（querySqlSync + executeSync）：单线程下不会与另一次入队交错，
   * 连续「标已读 → 标收藏」不会互相覆盖。
   */
  enqueueState(articleId: string, read: boolean | undefined, starred: boolean | undefined): void {
    if (articleId.length === 0 || (read === undefined && starred === undefined)) {
      return;
    }
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return;
    }
    try {
      const item: OutboxItem = this.loadOutboxItem(articleId);
      item.articleId = articleId;
      if (read !== undefined) {
        item.setRead = true;
        item.readValue = read;
      }
      if (starred !== undefined) {
        item.setStarred = true;
        item.starredValue = starred;
      }
      item.updatedAt = Date.now();
      item.retries = 0;
      item.lastError = '';
      store.executeSync('INSERT OR REPLACE INTO ' + ArticleDbConstants.TABLE_SYNC_OUTBOX +
        ' (article_id, set_read, read_value, set_starred, starred_value, updated_at, retries, last_error)' +
        ' VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [item.articleId, item.setRead ? 1 : 0, item.readValue ? 1 : 0,
          item.setStarred ? 1 : 0, item.starredValue ? 1 : 0,
          item.updatedAt, item.retries, item.lastError]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'enqueueState failed: %{public}d', error.code);
    }
  }

  private loadOutboxItem(articleId: string): OutboxItem {
    const item: OutboxItem = new OutboxItem(articleId);
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return item;
    }
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync(
        'SELECT set_read, read_value, set_starred, starred_value, updated_at, retries, last_error' +
        ' FROM ' + ArticleDbConstants.TABLE_SYNC_OUTBOX + ' WHERE article_id = ?', [articleId]);
      try {
        if (rs.goToNextRow()) {
          item.setRead = rs.getLong(rs.getColumnIndex('set_read')) === 1;
          item.readValue = rs.getLong(rs.getColumnIndex('read_value')) === 1;
          item.setStarred = rs.getLong(rs.getColumnIndex('set_starred')) === 1;
          item.starredValue = rs.getLong(rs.getColumnIndex('starred_value')) === 1;
          item.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
          item.retries = rs.getLong(rs.getColumnIndex('retries'));
          item.lastError = rs.getString(rs.getColumnIndex('last_error'));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      return item;
    }
    return item;
  }

  /** 取一批待同步（按本地变更时间正序）。 */
  async pendingItems(limit: number): Promise<OutboxItem[]> {
    const store: relationalStore.RdbStore | undefined = this.db();
    const result: OutboxItem[] = [];
    if (store === undefined || limit <= 0) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT article_id, set_read, read_value, set_starred, starred_value, updated_at, retries, last_error' +
        ' FROM ' + ArticleDbConstants.TABLE_SYNC_OUTBOX + ' ORDER BY updated_at ASC LIMIT ?', [limit]);
      try {
        while (rs.goToNextRow()) {
          const item: OutboxItem = new OutboxItem(rs.getString(rs.getColumnIndex('article_id')));
          item.setRead = rs.getLong(rs.getColumnIndex('set_read')) === 1;
          item.readValue = rs.getLong(rs.getColumnIndex('read_value')) === 1;
          item.setStarred = rs.getLong(rs.getColumnIndex('set_starred')) === 1;
          item.starredValue = rs.getLong(rs.getColumnIndex('starred_value')) === 1;
          item.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
          item.retries = rs.getLong(rs.getColumnIndex('retries'));
          item.lastError = rs.getString(rs.getColumnIndex('last_error'));
          result.push(item);
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'pendingItems failed: %{public}d', error.code);
    }
    return result;
  }

  /** 确认已回写：从队列删除。 */
  async ackItems(articleIds: string[]): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined || articleIds.length === 0) {
      return;
    }
    try {
      store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_SYNC_OUTBOX +
        ' WHERE article_id IN (' + placeholders(articleIds.length) + ')', articleIds);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'ackItems failed: %{public}d', error.code);
    }
  }

  /** 回写失败：累加重试次数与最近错误。 */
  async failItem(articleId: string, error: string): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_SYNC_OUTBOX +
        ' SET retries = retries + 1, last_error = ? WHERE article_id = ?',
        [error, articleId]);
    } catch (err) {
      const errorObj: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'failItem failed: %{public}d', errorObj.code);
    }
  }

  /** 待同步条数。 */
  async pendingCount(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_SYNC_OUTBOX);
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      return 0;
    }
  }

  /** 清空待同步队列（退出登录 / 清除同步数据）。 */
  async clearOutbox(): Promise<void> {
    this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_SYNC_OUTBOX);
  }

  /** 清空文章映射（退出登录 / 清除同步数据）。 */
  async clearMappings(): Promise<void> {
    this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_REMOTE_ARTICLE_MAP);
  }

  /** 清空同步游标 / 时间戳。 */
  async clearState(): Promise<void> {
    this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_SYNC_STATE);
  }

  private exec(sql: string): void {
    const store: relationalStore.RdbStore | undefined = this.db();
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync(sql);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'exec failed: %{public}d', error.code);
    }
  }
}

export const remoteAccountStore: RemoteAccountStore = new RemoteAccountStore();
