/* 规则试运行的只读文章采样。 */
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { ArticleDbConstants } from '../common/constants/RssConstants';
import { articleDatabase } from './ArticleServices';

const DOMAIN: number = 0x0000;
const TAG: string = 'RuleStore';

/** 试运行采样用的轻量列（含纯文本正文，正文列可按需截断）。 */
const SAMPLE_COLUMNS: string =
  'id, feed_id, feed_title, title, link, summary, published_at, is_read, is_starred, is_saved,' +
  ' is_hidden, image_url, author, content, plain_text';

export class RuleSampleStore {
  /**
   * 试运行采样：按发布时间倒序取最近 limit 篇（含正文纯文本，供 content 字段匹配）。
   * 只读，不修改任何状态。
   */
  async sampleArticles(limit: number): Promise<Article[]> {
    const store: relationalStore.RdbStore | undefined = articleDatabase.getStore();
    const result: Article[] = [];
    if (store === undefined || limit <= 0) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT ' + SAMPLE_COLUMNS + ' FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' ORDER BY published_at DESC LIMIT ?', [limit]);
      try {
        while (rs.goToNextRow()) {
          result.push(this.sampleRow(rs));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'sampleArticles failed: %{public}d', error.code);
    }
    return result;
  }

  private sampleRow(rs: relationalStore.ResultSet): Article {
    const content: string = rs.getString(rs.getColumnIndex('content'));
    const plain: string = rs.getString(rs.getColumnIndex('plain_text'));
    const article: Article = new Article(
      rs.getString(rs.getColumnIndex('id')),
      rs.getString(rs.getColumnIndex('feed_id')),
      rs.getString(rs.getColumnIndex('feed_title')),
      rs.getString(rs.getColumnIndex('title')),
      rs.getString(rs.getColumnIndex('link')),
      rs.getString(rs.getColumnIndex('summary')),
      content,
      rs.getLong(rs.getColumnIndex('published_at')));
    article.plainText = plain;
    article.imageUrl = rs.getString(rs.getColumnIndex('image_url'));
    article.author = rs.getString(rs.getColumnIndex('author'));
    article.read = rs.getLong(rs.getColumnIndex('is_read')) === 1;
    article.starred = rs.getLong(rs.getColumnIndex('is_starred')) === 1;
    article.saved = rs.getLong(rs.getColumnIndex('is_saved')) === 1;
    article.hidden = rs.getLong(rs.getColumnIndex('is_hidden')) === 1;
    return article;
  }

}
