/* 标签与文章关联的备份搬运；沿用应用唯一的数据库连接。 */
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BackupArticleTag } from '../model/Backup';
import { articleDatabase } from './ArticleServices';
import { BACKUP_BATCH_SIZE, SQL_SELECT_BACKUP_ARTICLE_TAGS, SQL_INSERT_BACKUP_ARTICLE_TAG } from './ArticleSchema';

const DOMAIN: number = 0x0000;
const TAG: string = 'TagStore';

export class TagRelationsBackup {
  private readonly changes: () => number;

  constructor(changes: () => number) {
    this.changes = changes;
  }

  private lastChanges(): number {
    return this.changes();
  }

  /** 导出文章 ↔ 标签关联（全表）。 */
  async allArticleTagsForBackup(): Promise<BackupArticleTag[]> {
    const store: relationalStore.RdbStore | undefined = articleDatabase.getStore();
    const result: BackupArticleTag[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(SQL_SELECT_BACKUP_ARTICLE_TAGS);
      try {
        while (rs.goToNextRow()) {
          result.push(new BackupArticleTag(
            rs.getString(rs.getColumnIndex('article_id')),
            rs.getString(rs.getColumnIndex('tag_id'))));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const message: string = err instanceof Error ? err.message : 'unknown error';
      hilog.error(DOMAIN, TAG, 'allArticleTagsForBackup failed: %{public}s', message);
    }
    return result;
  }

  /** 导入关联：INSERT OR IGNORE，返回实际新增条数（联合主键已存在不计）。 */
  async mergeArticleTagsForBackup(records: BackupArticleTag[]): Promise<number> {
    const store: relationalStore.RdbStore | undefined = articleDatabase.getStore();
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
            const item: BackupArticleTag = records[i];
            if (item.articleId.length === 0 || item.tagId.length === 0) {
              continue;
            }
            store.executeSync(SQL_INSERT_BACKUP_ARTICLE_TAG, [item.articleId, item.tagId]);
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
        hilog.error(DOMAIN, TAG, 'mergeArticleTagsForBackup batch failed: %{public}s', message);
      }
      if (end < records.length) {
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 0));
      }
    }
    return added;
  }

}
