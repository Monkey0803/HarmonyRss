/* Idempotent table and column repair on the shared article database connection. */
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ArticleDbConstants } from '../common/constants/RssConstants';
import { DOMAIN, TAG, SQL_ADD_IMAGE, SQL_ADD_AUTHOR, SQL_ADD_PROGRESS, SQL_ADD_PROGRESS_RATIO,
  SQL_ADD_CONTENT_HTML, SQL_ADD_PAGE_ETAG, SQL_ADD_PAGE_LAST_MODIFIED, SQL_ADD_PLAIN_TEXT,
  SQL_ADD_SAVED, SQL_ADD_READER, SQL_ADD_HIDDEN, SQL_ADD_LINK_KEY, SQL_ADD_TITLE_KEY,
  SQL_ADD_CANONICAL, SQL_ADD_ENCLOSURES, SQL_ADD_MEDIA_PROGRESS, SQL_CREATE_TAGS,
  SQL_CREATE_FEEDS, SQL_CREATE_ARTICLE_TAGS, SQL_CREATE_SMART_FOLDERS, SQL_INDEXES_V4,
  SQL_CREATE_REMOTE_ACCOUNTS, SQL_CREATE_SYNC_STATE, SQL_CREATE_REMOTE_MAP,
  SQL_CREATE_SYNC_OUTBOX, SQL_CREATE_SYNC_RECORDS, SQL_INDEXES_V9, SQL_INDEXES_V5,
  SQL_CREATE_RULES, SQL_INDEXES_V6, SQL_INDEXES_V7 } from './ArticleSchema';

export class ArticleTableMigrator {
  private store: relationalStore.RdbStore | undefined;

  constructor(store: relationalStore.RdbStore | undefined) {
    this.store = store;
  }

  public createFeedTables(): void {
    try {
      this.store?.executeSync(SQL_CREATE_FEEDS);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'create feed table failed: %{public}d', error.code);
    }
  }

  public createTagTables(): void {
    const statements: string[] = [SQL_CREATE_TAGS, SQL_CREATE_ARTICLE_TAGS, SQL_CREATE_SMART_FOLDERS];
    for (let i = 0; i < statements.length; i += 1) {
      try {
        this.store?.executeSync(statements[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.error(DOMAIN, TAG, 'create tag table failed: %{public}d', error.code);
      }
    }
    for (let i = 0; i < SQL_INDEXES_V4.length; i += 1) {
      try {
        this.store?.executeSync(SQL_INDEXES_V4[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create tag index failed: %{public}d', error.code);
      }
    }
  }

  public createRemoteTables(): void {
    const statements: string[] = [
      SQL_CREATE_REMOTE_ACCOUNTS, SQL_CREATE_SYNC_STATE,
      SQL_CREATE_REMOTE_MAP, SQL_CREATE_SYNC_OUTBOX, SQL_CREATE_SYNC_RECORDS
    ];
    for (let i = 0; i < statements.length; i += 1) {
      try {
        this.store?.executeSync(statements[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.error(DOMAIN, TAG, 'create remote table failed: %{public}d', error.code);
      }
    }
    for (let i = 0; i < SQL_INDEXES_V5.length; i += 1) {
      try {
        this.store?.executeSync(SQL_INDEXES_V5[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create remote index failed: %{public}d', error.code);
      }
    }
    for (let i = 0; i < SQL_INDEXES_V9.length; i += 1) {
      try {
        this.store?.executeSync(SQL_INDEXES_V9[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create sync record index failed: %{public}d', error.code);
      }
    }
  }

  public createRuleTables(): void {
    try {
      this.store?.executeSync(SQL_CREATE_RULES);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'create rules table failed: %{public}d', error.code);
    }
    for (let i = 0; i < SQL_INDEXES_V6.length; i += 1) {
      try {
        this.store?.executeSync(SQL_INDEXES_V6[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create rules index failed: %{public}d', error.code);
      }
    }
  }

  public createDedupeIndexes(): void {
    for (let i = 0; i < SQL_INDEXES_V7.length; i += 1) {
      try {
        this.store?.executeSync(SQL_INDEXES_V7[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create dedupe index failed: %{public}d', error.code);
      }
    }
  }

  public ensureArticleColumns(): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    const migrations: string[] = [
      SQL_ADD_IMAGE, SQL_ADD_AUTHOR, SQL_ADD_PROGRESS, SQL_ADD_PROGRESS_RATIO,
      SQL_ADD_READER, SQL_ADD_CONTENT_HTML, SQL_ADD_PLAIN_TEXT, SQL_ADD_PAGE_ETAG,
      SQL_ADD_PAGE_LAST_MODIFIED, SQL_ADD_SAVED, SQL_ADD_HIDDEN, SQL_ADD_LINK_KEY,
      SQL_ADD_TITLE_KEY, SQL_ADD_CANONICAL, SQL_ADD_ENCLOSURES, SQL_ADD_MEDIA_PROGRESS
    ];
    const columns: Set<string> = new Set<string>();
    let inspected: boolean = false;
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync(
        'PRAGMA table_info(' + ArticleDbConstants.TABLE_ARTICLES + ')');
      try {
        while (rs.goToNextRow()) {
          columns.add(rs.getString(rs.getColumnIndex('name')));
        }
        inspected = columns.size > 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'column inspection failed, falling back to ALTER checks');
    }
    for (let i = 0; i < migrations.length; i += 1) {
      const sql: string = migrations[i];
      const column: string = sql.split(' ADD COLUMN ')[1].split(' ')[0];
      if (!inspected || !columns.has(column)) {
        this.addColumnIfNeeded(sql);
      }
    }
  }

  public addColumnIfNeeded(sql: string): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync(sql);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.info(DOMAIN, TAG, 'column already present: %{public}d', error.code);
    }
  }
}
