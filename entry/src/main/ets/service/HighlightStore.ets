/* Highlights and highlight backup, sharing the article database connection. */
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ArticleDbConstants } from '../common/constants/RssConstants';
import { Highlight, HighlightLibraryItem } from '../model/Highlight';
import { BackupHighlight } from '../model/Backup';
import { ArticleDatabase } from './ArticleDatabase';
import { DOMAIN, TAG, BACKUP_BATCH_SIZE, SQL_SELECT_BACKUP_HIGHLIGHTS, SQL_INSERT_BACKUP_HIGHLIGHT } from './ArticleSchema';

export class HighlightStore {
  private readonly database: ArticleDatabase;

  constructor(database: ArticleDatabase) {
    this.database = database;
  }

  // ---- 正文标注（highlight）CRUD ----

  /** 新增一条标注。 */
  addHighlight(item: Highlight): void {
    this.exec('INSERT OR REPLACE INTO ' + ArticleDbConstants.TABLE_HIGHLIGHTS +
      ' (id, article_id, quote, note, color, created_at, anchor_text, anchor_ratio)' +
      ' VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [item.id, item.articleId, item.quote, item.note, item.color, item.createdAt,
        item.anchorText, item.anchorRatio]);
  }

  /** 列出某篇文章的标注（按创建时间正序：与正文阅读顺序大致一致）。 */
  async listHighlights(articleId: string): Promise<Highlight[]> {
    const store: relationalStore.RdbStore | undefined = this.database.getStore();
    const result: Highlight[] = [];
    if (store === undefined || articleId.length === 0) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id, article_id, quote, note, color, created_at, anchor_text, anchor_ratio FROM ' +
        ArticleDbConstants.TABLE_HIGHLIGHTS + ' WHERE article_id = ? ORDER BY created_at ASC',
        [articleId]);
      try {
        while (rs.goToNextRow()) {
          result.push(new Highlight(
            rs.getString(rs.getColumnIndex('id')),
            rs.getString(rs.getColumnIndex('article_id')),
            rs.getString(rs.getColumnIndex('quote')),
            rs.getString(rs.getColumnIndex('note')),
            rs.getString(rs.getColumnIndex('color')),
            rs.getLong(rs.getColumnIndex('created_at')),
            rs.getString(rs.getColumnIndex('anchor_text')),
            rs.getDouble(rs.getColumnIndex('anchor_ratio'))));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'listHighlights failed: %{public}d', error.code);
    }
    return result;
  }

  /** 改备注。 */
  updateHighlightNote(id: string, note: string): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_HIGHLIGHTS + ' SET note = ? WHERE id = ?',
      [note, id]);
  }

  /** 改配色。 */
  updateHighlightColor(id: string, color: string): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_HIGHLIGHTS + ' SET color = ? WHERE id = ?',
      [color, id]);
  }

  /** 删除一条标注。 */
  deleteHighlight(id: string): void {
    this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_HIGHLIGHTS + ' WHERE id = ?', [id]);
  }

  /**
   * 全部标注（JOIN 文章表拿标题 / 链接 / 来源），按创建时间倒序。
   * 文章被删掉时用 LEFT JOIN 仍能带出标注（标题为空），避免标注凭空消失。
   */
  async listAllHighlights(): Promise<HighlightLibraryItem[]> {
    const store: relationalStore.RdbStore | undefined = this.database.getStore();
    const result: HighlightLibraryItem[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT h.id AS hid, h.article_id AS aid, h.quote AS quote, h.note AS note, h.color AS color,' +
        ' h.created_at AS created, h.anchor_text AS anchor, h.anchor_ratio AS ratio,' +
        ' COALESCE(a.title, \'\') AS atitle, COALESCE(a.link, \'\') AS alink,' +
        ' COALESCE(a.feed_title, \'\') AS fname' +
        ' FROM ' + ArticleDbConstants.TABLE_HIGHLIGHTS + ' h' +
        ' LEFT JOIN ' + ArticleDbConstants.TABLE_ARTICLES + ' a ON a.id = h.article_id' +
        ' ORDER BY h.created_at DESC');
      try {
        while (rs.goToNextRow()) {
          const item: Highlight = new Highlight(
            rs.getString(rs.getColumnIndex('hid')),
            rs.getString(rs.getColumnIndex('aid')),
            rs.getString(rs.getColumnIndex('quote')),
            rs.getString(rs.getColumnIndex('note')),
            rs.getString(rs.getColumnIndex('color')),
            rs.getLong(rs.getColumnIndex('created')),
            rs.getString(rs.getColumnIndex('anchor')),
            rs.getDouble(rs.getColumnIndex('ratio')));
          result.push(new HighlightLibraryItem(item,
            rs.getString(rs.getColumnIndex('atitle')),
            rs.getString(rs.getColumnIndex('alink')),
            rs.getString(rs.getColumnIndex('fname'))));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'listAllHighlights failed: %{public}d', error.code);
    }
    return result;
  }

  /** 统计标注总数（设置页「储存」区展示用）。 */
  async countHighlights(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.database.getStore();
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_HIGHLIGHTS);
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'countHighlights failed: %{public}d', error.code);
      return 0;
    }
  }

  /** 导出标注段（全表）。 */
  async allHighlightsForBackup(): Promise<BackupHighlight[]> {
    const store: relationalStore.RdbStore | undefined = this.database.getStore();
    const result: BackupHighlight[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(SQL_SELECT_BACKUP_HIGHLIGHTS);
      try {
        while (rs.goToNextRow()) {
          result.push(new BackupHighlight(
            rs.getString(rs.getColumnIndex('id')),
            rs.getString(rs.getColumnIndex('article_id')),
            rs.getString(rs.getColumnIndex('quote')),
            rs.getString(rs.getColumnIndex('note')),
            rs.getString(rs.getColumnIndex('color')),
            rs.getLong(rs.getColumnIndex('created_at')),
            rs.getString(rs.getColumnIndex('anchor_text')),
            rs.getDouble(rs.getColumnIndex('anchor_ratio'))));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const message: string = err instanceof Error ? err.message : 'unknown error';
      hilog.error(DOMAIN, TAG, 'allHighlightsForBackup failed: %{public}s', message);
    }
    return result;
  }

  /** 导入标注段：INSERT OR IGNORE，返回实际新增条数（已有 id 不计）。 */
  async mergeHighlightsForBackup(records: BackupHighlight[]): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.database.getStore();
    if (store === undefined || records.length === 0) {
      return 0;
    }
    let added: number = 0;
    for (let start = 0; start < records.length; start += BACKUP_BATCH_SIZE) {
      const end: number = Math.min(start + BACKUP_BATCH_SIZE, records.length);
      let batchAdded: number = 0;
      try {
        store.beginTransaction();
        try {
          for (let i = start; i < end; i += 1) {
            const item: BackupHighlight = records[i];
            if (item.id.length === 0 || item.articleId.length === 0) {
              continue;
            }
            store.executeSync(SQL_INSERT_BACKUP_HIGHLIGHT, [
              item.id, item.articleId, item.quote, item.note, item.color, item.createdAt,
              item.anchorText, item.anchorRatio
            ]);
            if (this.lastChanges() > 0) {
              batchAdded += 1;
            }
          }
          store.commit();
        } catch (inner) {
          store.rollBack();
          throw inner as Error;
        }
        added += batchAdded;
      } catch (err) {
        const message: string = err instanceof Error ? err.message : 'unknown error';
        hilog.error(DOMAIN, TAG, 'mergeHighlightsForBackup batch failed: %{public}s', message);
      }
    }
    return added;
  }

  private lastChanges(): number {
    const store: relationalStore.RdbStore | undefined = this.database.getStore();
    if (store === undefined) { return 0; }
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync('SELECT changes() AS c');
      try { return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0; }
      finally { rs.close(); }
    } catch (err) { return 0; }
  }

  private exec(sql: string, args: Array<relationalStore.ValueType>): void {
    const store: relationalStore.RdbStore | undefined = this.database.getStore();
    if (store === undefined) { return; }
    try { store.executeSync(sql, args); }
    catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'exec failed: %{public}d', error.code);
    }
  }
}
