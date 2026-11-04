/* Backup article segment uses the repository's shared RDB connection. */
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WEB_PAGE_FEED_ID } from '../model/WebPagePreview';
import { ArticleStatePatch, BackupArticle } from '../model/Backup';
import { mergeArticleState } from './BackupCodec';
import { DOMAIN, TAG, BackupMergeCount, BACKUP_BATCH_SIZE, SQL_SELECT_BACKUP_ARTICLES,
  SQL_SELECT_BACKUP_ARTICLE_STATE, SQL_INSERT_BACKUP_ARTICLE,
  SQL_UPDATE_BACKUP_ARTICLE_STATE } from './ArticleSchema';

export class ArticleBackupRepository {
  private store: relationalStore.RdbStore | undefined;

  constructor(store: relationalStore.RdbStore | undefined) {
    this.store = store;
  }

  async allArticlesForBackup(): Promise<BackupArticle[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: BackupArticle[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(SQL_SELECT_BACKUP_ARTICLES);
      try {
        while (rs.goToNextRow()) {
          result.push(new BackupArticle(
            rs.getString(0), rs.getString(1), rs.getString(2), rs.getString(3),
            rs.getString(4), rs.getString(5), rs.getString(6), rs.getLong(7),
            rs.getString(8), rs.getLong(9) === 1, rs.getLong(10) === 1,
            rs.getLong(11) === 1, rs.getLong(14) === 1, rs.getDouble(12),
            rs.getDouble(13), rs.getString(15), rs.getString(16), rs.getString(17)));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const message: string = err instanceof Error ? err.message : 'unknown error';
      hilog.error(DOMAIN, TAG, 'allArticlesForBackup failed: %{public}s', message);
    }
    return result;
  }

  async mergeArticlesForBackup(records: BackupArticle[],
    validFeedIds: string[]): Promise<BackupMergeCount> {
    const counts: BackupMergeCount = new BackupMergeCount();
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || records.length === 0) {
      return counts;
    }
    const allowed: Set<string> = new Set<string>();
    // 独立保存的网页没有订阅源记录，但属于可备份的本地文章。
    allowed.add(WEB_PAGE_FEED_ID);
    for (let i = 0; i < validFeedIds.length; i += 1) {
      allowed.add(validFeedIds[i]);
    }
    const now: number = Date.now();
    for (let start = 0; start < records.length; start += BACKUP_BATCH_SIZE) {
      const end: number = Math.min(start + BACKUP_BATCH_SIZE, records.length);
      let batchAdded: number = 0;
      let batchUpdated: number = 0;
      let batchSkipped: number = 0;
      try {
        store.beginTransaction();
        try {
          for (let i = start; i < end; i += 1) {
            const record: BackupArticle = records[i];
            if (record.id.length === 0 || !allowed.has(record.feedId)) {
              batchSkipped += 1;
              continue;
            }
            const existing: ArticleStatePatch | undefined =
              this.readBackupArticleState(store, record.id);
            if (existing === undefined) {
              store.executeSync(SQL_INSERT_BACKUP_ARTICLE, [
                record.id, record.feedId, record.feedTitle, record.title, record.link,
                record.summary, '', record.publishedAt,
                record.read ? 1 : 0, record.starred ? 1 : 0, record.saved ? 1 : 0,
                record.hidden ? 1 : 0, now, record.imageUrl, record.author,
                record.progress, record.progressRatio, record.linkKey, record.titleKey,
                record.canonicalId
              ]);
              batchAdded += 1;
            } else {
              const merged: ArticleStatePatch = mergeArticleState(existing, record);
              store.executeSync(SQL_UPDATE_BACKUP_ARTICLE_STATE, [
                merged.read ? 1 : 0, merged.starred ? 1 : 0, merged.saved ? 1 : 0,
                merged.hidden ? 1 : 0, merged.progress, merged.progressRatio,
                merged.canonicalId, record.id
              ]);
              batchUpdated += 1;
            }
          }
          store.commit();
        } catch (inner) {
          store.rollBack();
          throw inner as Error;
        }
        counts.added += batchAdded;
        counts.updated += batchUpdated;
        counts.skipped += batchSkipped;
      } catch (err) {
        const message: string = err instanceof Error ? err.message : 'unknown error';
        hilog.error(DOMAIN, TAG, 'mergeArticlesForBackup batch failed: %{public}s', message);
      }
      if (end < records.length) {
        // 事务已结束才让出 UI 任务；下一批继续时仍保持逐批提交与回滚语义。
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 0));
      }
    }
    return counts;
  }

  private readBackupArticleState(store: relationalStore.RdbStore,
    id: string): ArticleStatePatch | undefined {
    const rs: relationalStore.ResultSet = store.querySqlSync(SQL_SELECT_BACKUP_ARTICLE_STATE, [id]);
    try {
      if (!rs.goToNextRow()) {
        return undefined;
      }
      return new ArticleStatePatch(
        rs.getLong(1) === 1,
        rs.getLong(2) === 1,
        rs.getLong(3) === 1,
        rs.getLong(4) === 1,
        rs.getDouble(5),
        rs.getDouble(6),
        rs.getString(7));
    } finally {
      rs.close();
    }
  }
}
