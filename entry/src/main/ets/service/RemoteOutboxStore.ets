/* 同步发件箱存储：复用 ArticleDatabase 的同一连接。 */
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ArticleDbConstants } from '../common/constants/RssConstants';
import { OutboxItem } from '../model/Remote';
import { articleDatabase } from './ArticleServices';

const DOMAIN: number = 0x0000;
const TAG: string = 'RemoteAccountStore';

function placeholders(count: number): string {
  const parts: string[] = [];
  for (let i = 0; i < count; i += 1) {
    parts.push('?');
  }
  return parts.join(',');
}

export class RemoteOutboxStore {
  protected db(): relationalStore.RdbStore | undefined {
    return articleDatabase.getStore();
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
          item.setRead = rs.getLong(0) === 1;
          item.readValue = rs.getLong(1) === 1;
          item.setStarred = rs.getLong(2) === 1;
          item.starredValue = rs.getLong(3) === 1;
          item.updatedAt = rs.getLong(4);
          item.retries = rs.getLong(5);
          item.lastError = rs.getString(6);
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
          const item: OutboxItem = new OutboxItem(rs.getString(0));
          item.setRead = rs.getLong(1) === 1;
          item.readValue = rs.getLong(2) === 1;
          item.setStarred = rs.getLong(3) === 1;
          item.starredValue = rs.getLong(4) === 1;
          item.updatedAt = rs.getLong(5);
          item.retries = rs.getLong(6);
          item.lastError = rs.getString(7);
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

  protected exec(sql: string): void {
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
