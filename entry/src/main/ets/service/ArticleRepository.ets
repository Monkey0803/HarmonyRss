/* Article records, offline state, deduplication, trash and backup. */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { WEB_PAGE_FEED_ID } from '../model/WebPagePreview';
import { WebPagePayload } from '../model/Sync';
import {
  ArticleStatePatch,
  BackupArticle,
  BackupArticleTag,
  BackupHighlight
} from '../model/Backup';
import { mergeArticleState } from './BackupCodec';
import { DedupeCandidate, GroupSource } from '../model/Dedupe';
import { appSettings } from '../model/AppSettings';
import { Highlight, HighlightLibraryItem } from '../model/Highlight';
import { ArticleState, RemoteMapping } from '../model/Remote';
import {
  CjkQueryPlan,
  FeedStorageStat,
  RetentionCandidate,
  RetentionPolicy,
  SearchDiagnostics,
  SearchHit,
  SearchPage,
  SearchQuery,
  SearchState,
  StorageStats
} from '../model/Search';
import { ArticleDbConstants, ReaderState, RssConstants, SearchConstants } from '../common/constants/RssConstants';
import { RetentionMode } from '../common/constants/SettingsConstants';
import { toPlainText } from '../common/utils/HtmlText';
import { summarizeForList } from '../common/utils/SummaryText';
import { escapeFtsToken } from './SearchQueryParser';
import { compile, hasCjk, isBlankQuery, postFilterSql } from './SearchPlan';
import { grams } from './CjkTokenizer';
import { DedupeKeys } from './DedupeKeys';
import { DedupeService } from './DedupeService';
import { decodeEnclosures, encodeEnclosures } from './EnclosureCodec';
import { Enclosure } from '../model/Enclosure';

import { ArticleSearchStore } from './ArticleSearchStore';
import { DOMAIN, TAG, SavedWebPageResult, BODY_COLUMNS, LIST_COLUMNS, DEDUPE_KEY_BATCH, SQL_INSERT, BACKUP_BATCH_SIZE, SQL_SELECT_BACKUP_ARTICLES, SQL_SELECT_BACKUP_ARTICLE_STATE, SQL_INSERT_BACKUP_ARTICLE, SQL_UPDATE_BACKUP_ARTICLE_STATE, SQL_SELECT_BACKUP_ARTICLE_TAGS, SQL_INSERT_BACKUP_ARTICLE_TAG, SQL_SELECT_LIST, SQL_SELECT_FETCHED_SINCE, SQL_SELECT_BODY, SQL_UPSERT_REMOTE_MAP, ArticleBody, CacheStats, SummaryFix, WidgetSnapshot, placeholders, BackupMergeCount } from './ArticleSchema';

export class ArticleRepository extends ArticleSearchStore {
  /** 本地缓存条数（后台任务用它做插入前后的差值，得到真正的新增数）。 */
  async countAll(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet =
        await store.querySql('SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_ARTICLES);
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'countAll failed: %{public}d', error.code);
      return 0;
    }
  }

  /** 卡片快照：一次计数 + 一次取标题，避免为了一个数字把全库读出来。 */
  async widgetSnapshot(limit: number): Promise<WidgetSnapshot> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return new WidgetSnapshot(0, [], [], 0);
    }
    let unread: number = 0;
    let lastFetchedAt: number = 0;
    const titles: string[] = [];
    const ids: string[] = [];
    try {
      const countRs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE is_read = 0 AND is_hidden = 0 AND canonical_id = \'\'');
      try {
        unread = countRs.goToNextRow() ? countRs.getLong(countRs.getColumnIndex('c')) : 0;
      } finally {
        countRs.close();
      }
      const titleRs: relationalStore.ResultSet = await store.querySql(
        'SELECT id, title FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE is_hidden = 0 AND canonical_id = \'\' ORDER BY published_at DESC LIMIT ?', [limit]);
      try {
        while (titleRs.goToNextRow() && titles.length < limit) {
          titles.push(titleRs.getString(titleRs.getColumnIndex('title')));
          ids.push(titleRs.getString(titleRs.getColumnIndex('id')));
        }
      } finally {
        titleRs.close();
      }
      // 最近抓取时间：卡片上显示「最近同步」用（取全库最大值，不依赖内存状态）。
      const fetchRs: relationalStore.ResultSet = await store.querySql(
        'SELECT COALESCE(MAX(fetched_at), 0) AS f FROM ' + ArticleDbConstants.TABLE_ARTICLES);
      try {
        lastFetchedAt = fetchRs.goToNextRow() ? fetchRs.getLong(fetchRs.getColumnIndex('f')) : 0;
      } finally {
        fetchRs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'widgetSnapshot failed: %{public}d', error.code);
    }
    return new WidgetSnapshot(unread, titles, ids, lastFetchedAt);
  }

  /**
   * 轻量列表：只读元数据（不含正文 HTML / 纯文本），按发布时间倒序。
   * 列表规模可能上万条，正文必须走 loadBody 按需加载。
   */
  async loadForList(): Promise<Article[]> {
    const startedAt: number = Date.now();
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: Article[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(SQL_SELECT_LIST);
      try {
        while (rs.goToNextRow()) {
          result.push(this.articleFromListRow(rs));
        }
      } finally {
        rs.close();
      }
      const duplicateCounts: Map<string, number> = new Map<string, number>();
      const counts: relationalStore.ResultSet = await store.querySql(
        'SELECT canonical_id, COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE canonical_id <> \'\' GROUP BY canonical_id');
      try {
        while (counts.goToNextRow()) {
          duplicateCounts.set(counts.getString(0), counts.getLong(1));
        }
      } finally {
        counts.close();
      }
      for (let i = 0; i < result.length; i += 1) {
        result[i].duplicateCount = 1 + (duplicateCounts.get(result[i].id) ?? 0);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'loadForList failed: %{public}d', error.code);
    }
    hilog.info(DOMAIN, TAG, 'startup listLoad=%{public}dms rows=%{public}d',
      Date.now() - startedAt, result.length);
    return result;
  }

  /** SQLite 外部连接写入版本；分享扩展保存后主界面据此按需重载。 */
  dataVersion(): number {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync('PRAGMA data_version');
      try {
        return rs.goToNextRow() ? rs.getLong(0) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      return 0;
    }
  }

  /**
   * 某时刻之后入库的新文章（轻量列）：未读 + 未隐藏 + 非重复项，按发布时间倒序。
   * 每日摘要的数据源（`ts` 一般是当天 00:00），不做正文 / HTML 读取。
   */
  async articlesFetchedSince(ts: number): Promise<Article[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: Article[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(SQL_SELECT_FETCHED_SINCE, [ts]);
      try {
        while (rs.goToNextRow()) {
          result.push(this.articleFromListRow(rs));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'articlesFetchedSince failed: %{public}d', error.code);
    }
    return result;
  }

  /**
   * 媒体队列：主条、未隐藏、带 enclosure 的文章，按发布时间倒序。
   * @param feedId 限定来源；allFeeds=true 时忽略。
   * @param onlyUnplayed 只取 media_progress = 0 的（未开始过的）音频。
   * 返回前在内存里过滤出音频（enclosure 可能全是视频）。
   */
  async loadMediaQueue(feedId: string, allFeeds: boolean, onlyUnplayed: boolean,
    limit: number = 50): Promise<Article[]> {
    await this.whenReady();
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return [];
    }
    const params: relationalStore.ValueType[] = [];
    let sql: string = 'SELECT ' + LIST_COLUMNS + ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a' +
      ' WHERE a.canonical_id = \'\' AND a.is_hidden = 0 AND a.enclosures <> \'[]\'';
    if (!allFeeds) {
      sql += ' AND a.feed_id = ?';
      params.push(feedId);
    }
    if (onlyUnplayed) {
      sql += ' AND a.media_progress = 0';
    }
    sql += ' ORDER BY a.published_at DESC LIMIT ?';
    params.push(limit > 0 ? Math.floor(limit) : 50);
    const result: Article[] = [];
    try {
      const rs: relationalStore.ResultSet = await store.querySql(sql, params);
      try {
        while (rs.goToNextRow()) {
          const article: Article = this.articleFromListRow(rs);
          for (let i = 0; i < article.enclosures.length; i += 1) {
            const enclosure: Enclosure = article.enclosures[i];
            if (enclosure.isAudio()) {
              result.push(article);
              break;
            }
          }
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'loadMediaQueue failed: %{public}d', error.code);
    }
    return result;
  }

  /** 写音频播放进度（秒）；0 表示未听。 */
  async setMediaProgress(articleId: string, seconds: number): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || articleId.length === 0) {
      return;
    }
    const value: number = Number.isFinite(seconds) && seconds > 0 ? Math.floor(seconds) : 0;
    try {
      store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
        ' SET media_progress = ? WHERE id = ?', [value, articleId]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setMediaProgress failed: %{public}d', error.code);
    }
  }

  /**
   * 轻量列表行 → Article（loadForList / loadHidden 共用，字段映射保持一致）。
   * 正文列不在列表查询里，正文由 loadBody 按需加载。
   */
  private articleFromListRow(rs: relationalStore.ResultSet): Article {
    // LIST_COLUMNS 和 LIST_FAST_COLUMNS 使用相同的固定列序。
    // 逐行按名称查列会在万篇列表上执行数十万次 getColumnIndex。
    const article: Article = new Article(
      rs.getString(0),
      rs.getString(1),
      rs.getString(2),
      rs.getString(3),
      rs.getString(4),
      rs.getString(5),
      '',
      rs.getLong(6)
    );
    article.imageUrl = rs.getString(11);
    article.author = rs.getString(12);
    article.read = rs.getLong(7) === 1;
    article.starred = rs.getLong(8) === 1;
    article.saved = rs.getLong(9) === 1;
    article.hidden = rs.getLong(10) === 1;
    // 用 getDouble 读：老数据里可能残留小数（列是 INTEGER，但 SQLite 动态类型允许 REAL）。
    article.progress = rs.getDouble(13);
    article.progressRatio = rs.getDouble(14);
    article.readerState = rs.getLong(15) === 1
      ? ReaderState.READY
      : ReaderState.NONE;
    article.offlineState = rs.getString(16);
    // 跨源去重：canonical_id 空串 = 主条；duplicateCount 是「含自己的组内来源数」。
    article.canonicalId = rs.getString(17);
    article.duplicateCount = 1 + rs.getLong(20);
    article.enclosures = decodeEnclosures(rs.getString(18));
    article.mediaProgress = rs.getLong(19);
    return article;
  }

  /** 兼容旧调用：列表读取（轻量列）。 */
  async loadRecent(): Promise<Article[]> {
    return await this.loadForList();
  }

  /** 每源最近的未读主条；只读轻量列，供用户选定范围后准备离线正文。 */
  async offlineCandidates(feedId: string, limit: number = 20): Promise<Article[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || feedId.length === 0) {
      return [];
    }
    const result: Article[] = [];
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT ' + LIST_COLUMNS + ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a' +
        ' WHERE a.feed_id = ? AND a.is_read = 0 AND a.is_hidden = 0 AND a.canonical_id = \'\'' +
        ' ORDER BY a.published_at DESC LIMIT ?', [feedId, Math.max(1, Math.min(20, Math.floor(limit)))]);
      try {
        while (rs.goToNextRow()) {
          result.push(this.articleFromListRow(rs));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'offline candidates failed: %{public}d', error.code);
    }
    return result;
  }

  /** Reader 缓存状态由持久化标记判定，避免把 feed 摘要误报成完整离线正文。 */
  async offlineState(id: string): Promise<string> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || id.length === 0) {
      return 'none';
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT substr(reader_html, 1, 13) AS marker FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE id = ?', [id]);
      try {
        if (!rs.goToNextRow()) {
          return 'none';
        }
        const marker: string = rs.getString(rs.getColumnIndex('marker'));
        if (marker.startsWith('<!--hrv9p-->')) {
          return 'partial';
        }
        if (marker.startsWith('<!--hrv9t-->')) {
          return 'text';
        }
        return marker.startsWith('<!--hrv9-->') || marker.startsWith('<!--hrv8-->') ? 'full' : 'none';
      } finally {
        rs.close();
      }
    } catch (err) {
      return 'none';
    }
  }

  /** 按 id 读正文相关列；不存在返回 undefined。 */
  async loadBody(id: string): Promise<ArticleBody | undefined> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || id.length === 0) {
      return undefined;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(SQL_SELECT_BODY, [id]);
      try {
        if (!rs.goToNextRow()) {
          return undefined;
        }
        return new ArticleBody(
          rs.getString(rs.getColumnIndex('content')),
          rs.getString(rs.getColumnIndex('content_html')),
          rs.getString(rs.getColumnIndex('reader_html')),
          rs.getString(rs.getColumnIndex('plain_text')),
          rs.getString(rs.getColumnIndex('page_etag')),
          rs.getString(rs.getColumnIndex('page_last_modified')));
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'loadBody failed: %{public}d', error.code);
      return undefined;
    }
  }

  /** 按网页地址查找已有文章，优先返回跨源去重后的主文章。 */
  async findByUrl(url: string): Promise<Article | undefined> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || url.length === 0) {
      return undefined;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id, canonical_id FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE link_key = ? OR link = ?' +
        ' ORDER BY CASE WHEN canonical_id = \'\' THEN 0 ELSE 1 END, published_at DESC LIMIT 1',
        [DedupeKeys.urlKey(url), url]);
      let id: string = '';
      try {
        if (rs.goToNextRow()) {
          const canonical: string = rs.getString(rs.getColumnIndex('canonical_id'));
          id = canonical.length > 0 ? canonical : rs.getString(rs.getColumnIndex('id'));
        }
      } finally {
        rs.close();
      }
      return id.length > 0 ? await this.loadById(id) : undefined;
    } catch (err) {
      return undefined;
    }
  }

  /** 按 id 读一篇文章（列表列 + 正文列）；用于「不在内存里」时的兜底加载。 */
  async loadById(id: string): Promise<Article | undefined> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || id.length === 0) {
      return undefined;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT ' + LIST_COLUMNS + ', ' + BODY_COLUMNS + ' FROM ' +
        ArticleDbConstants.TABLE_ARTICLES + ' a WHERE a.id = ?', [id]);
      try {
        if (!rs.goToNextRow()) {
          return undefined;
        }
        const article: Article = new Article(
          rs.getString(rs.getColumnIndex('id')),
          rs.getString(rs.getColumnIndex('feed_id')),
          rs.getString(rs.getColumnIndex('feed_title')),
          rs.getString(rs.getColumnIndex('title')),
          rs.getString(rs.getColumnIndex('link')),
          rs.getString(rs.getColumnIndex('summary')),
          rs.getString(rs.getColumnIndex('content')),
          rs.getLong(rs.getColumnIndex('published_at'))
        );
        article.imageUrl = rs.getString(rs.getColumnIndex('image_url'));
        article.author = rs.getString(rs.getColumnIndex('author'));
        article.read = rs.getLong(rs.getColumnIndex('is_read')) === 1;
        article.starred = rs.getLong(rs.getColumnIndex('is_starred')) === 1;
        article.saved = rs.getLong(rs.getColumnIndex('is_saved')) === 1;
        article.hidden = rs.getLong(rs.getColumnIndex('is_hidden')) === 1;
        article.progress = rs.getDouble(rs.getColumnIndex('progress'));
        article.progressRatio = rs.getDouble(rs.getColumnIndex('progress_ratio'));
        article.contentHtml = rs.getString(rs.getColumnIndex('content_html'));
        article.readerHtml = rs.getString(rs.getColumnIndex('reader_html'));
        article.plainText = rs.getString(rs.getColumnIndex('plain_text'));
        article.pageEtag = rs.getString(rs.getColumnIndex('page_etag'));
        article.pageLastModified = rs.getString(rs.getColumnIndex('page_last_modified'));
        article.readerState = article.readerHtml.length > 0 ? ReaderState.READY : ReaderState.NONE;
        article.canonicalId = rs.getString(rs.getColumnIndex('canonical_id'));
        article.duplicateCount = 1 + rs.getLong(rs.getColumnIndex('dup_count'));
        article.enclosures = decodeEnclosures(rs.getString(rs.getColumnIndex('enclosures')));
        article.mediaProgress = rs.getLong(rs.getColumnIndex('media_progress'));
        return article;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'loadById failed: %{public}d', error.code);
      return undefined;
    }
  }

  /**
   * 入库新抓到的文章：只插入不存在的行，已有行的已读 / 收藏状态保持不变；同步 FTS。
   *
   * 跨源去重：
   *   1. 先给每篇算好 link_key / title_key（与去重开关无关，始终写入）；
   *   2. 开关打开时按批查已有候选（URL 键一次、标题键 + ±24h 一次），在内存里定出主条；
   *   3. 重复项照常入库（保留来源与远端映射），但不写 FTS / 中文索引（列表与检索都排除它们）；
   *   4. 匹配或查询异常一律降级为独立文章（FR-011），只记日志。
   */
  insertNew(articles: Article[]): Article[] {
    const store: relationalStore.RdbStore | undefined = this.store;
    const created: Article[] = [];
    if (store === undefined || articles.length === 0) {
      return created;
    }
    const canonicalOf: Map<string, string> = this.resolveCanonicals(articles);
    const now: number = Date.now();
    try {
      store.beginTransaction();
      try {
        for (let i = 0; i < articles.length; i += 1) {
          const item: Article = articles[i];
          const canonical: string = canonicalOf.get(item.id) ?? '';
          item.canonicalId = canonical;
          store.executeSync(SQL_INSERT, [
            item.id, item.feedId, item.feedTitle, item.title, item.link,
            item.summary, item.content, item.publishedAt,
            item.read ? 1 : 0, item.starred ? 1 : 0, now, item.imageUrl, item.author, item.contentHtml,
            item.linkKey, item.titleKey, canonical, encodeEnclosures(item.enclosures)
          ]);
          // INSERT OR IGNORE：只有真正插入了新行（changes()=1）才建索引，避免覆盖已有正文索引。
          const inserted: boolean = this.lastChanges() > 0;
          if (inserted) {
            // 只有真正新增的行才算「新文章」：规则只对它们执行，历史文章不回溯。
            created.push(item);
            if (canonical.length === 0) {
              this.indexInserted(item);
            }
          }
        }
        store.commit();
      } catch (inner) {
        store.rollBack();
        throw inner as Error;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'insertNew failed: %{public}d', error.code);
      return [];
    }
    return created;
  }

  /** 保存独立网页；相同归一化链接若已有 RSS 文章，直接将原文章加入稍后读。 */
  saveWebPage(article: Article): SavedWebPageResult | undefined {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || article.link.length === 0) {
      return undefined;
    }
    const linkKey: string = DedupeKeys.urlKey(article.link);
    try {
      store.beginTransaction();
      try {
        let existingId: string = '';
        const rs: relationalStore.ResultSet = store.querySqlSync(
          'SELECT id, canonical_id FROM ' + ArticleDbConstants.TABLE_ARTICLES +
          ' WHERE link_key = ? OR link = ?' +
          ' ORDER BY CASE WHEN canonical_id = \'\' THEN 0 ELSE 1 END, published_at DESC LIMIT 1',
          [linkKey, article.link]);
        try {
          if (rs.goToNextRow()) {
            const canonical: string = rs.getString(rs.getColumnIndex('canonical_id'));
            existingId = canonical.length > 0 ? canonical : rs.getString(rs.getColumnIndex('id'));
          }
        } finally {
          rs.close();
        }
        if (existingId.length > 0) {
          store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
            ' SET is_saved = 1, is_hidden = 0 WHERE id = ?', [existingId]);
          if (article.readerHtml.length > 0) {
            store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
              ' SET reader_html = ?, plain_text = ? WHERE id = ? AND reader_html = \'\'',
              [article.readerHtml, article.plainText, existingId]);
            if (this.lastChanges() > 0) {
              this.upsertIndexFromRow(existingId, article.plainText);
            }
          }
          store.commit();
          return new SavedWebPageResult(existingId, false);
        }
        article.linkKey = linkKey;
        article.titleKey = DedupeKeys.titleKey(article.title);
        store.executeSync('INSERT INTO ' + ArticleDbConstants.TABLE_ARTICLES +
          ' (id, feed_id, feed_title, title, link, summary, content, published_at, is_saved, fetched_at,' +
          ' reader_html, plain_text, link_key, title_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?)',
          [article.id, article.feedId, article.feedTitle, article.title, article.link,
            article.summary, article.content, article.publishedAt, Date.now(), article.readerHtml,
            article.plainText, article.linkKey, article.titleKey]);
        this.indexInserted(article);
        store.commit();
        return new SavedWebPageResult(article.id, true);
      } catch (inner) {
        store.rollBack();
        throw inner as Error;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'save web page failed: %{public}d', error.code);
      return undefined;
    }
  }

  /**
   * 列出本机保存的独立网页（同步采集用，只取元数据，不含正文）。
   * 与列表同一口径：跨源重复里挂在主条下的网页不会出现两次。
   */
  async listSavedWebPages(): Promise<WebPagePayload[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: WebPagePayload[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT link, title, feed_title, summary, published_at FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE feed_id = ? ORDER BY published_at DESC', [WEB_PAGE_FEED_ID]);
      try {
        while (rs.goToNextRow()) {
          const link: string = rs.getString(rs.getColumnIndex('link'));
          if (link.length === 0) {
            continue;
          }
          result.push(new WebPagePayload(
            link,
            rs.getString(rs.getColumnIndex('title')),
            rs.getString(rs.getColumnIndex('feed_title')),
            rs.getString(rs.getColumnIndex('summary')),
            rs.getLong(rs.getColumnIndex('published_at'))));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'listWebPages failed: %{public}d %{public}s', error.code, error.message);
    }
    return result;
  }

  /**
   * 同步来的保存网页：本机没有则补一条（已存在不动，避免覆盖本地已读 / 进度）。
   * @returns 是否真的插入了新行
   */
  insertSyncedWebPage(urlKey: string, payload: WebPagePayload): boolean {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || urlKey.length === 0 || payload.url.length === 0) {
      return false;
    }
    const id: string = 'saved-web|' + urlKey;
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync(
        'SELECT 1 FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?', [id]);
      try {
        if (rs.goToNextRow()) {
          return false;
        }
      } finally {
        rs.close();
      }
      const article: Article = new Article(id, WEB_PAGE_FEED_ID,
        payload.source.length > 0 ? payload.source : payload.title,
        payload.title.length > 0 ? payload.title : payload.url,
        payload.url, payload.summary, payload.summary,
        payload.savedAt > 0 ? payload.savedAt : Date.now());
      article.saved = true;
      article.linkKey = urlKey;
      article.titleKey = DedupeKeys.titleKey(article.title);
      store.executeSync('INSERT INTO ' + ArticleDbConstants.TABLE_ARTICLES +
        ' (id, feed_id, feed_title, title, link, summary, content, published_at, is_saved, fetched_at,' +
        ' link_key, title_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)',
        [article.id, article.feedId, article.feedTitle, article.title, article.link,
          article.summary, article.content, article.publishedAt, Date.now(),
          article.linkKey, article.titleKey]);
      this.indexInserted(article);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'insert synced web page failed: %{public}d', error.code);
      return false;
    }
  }

  /** 删除一条独立网页（对端已删除时同步过来；只删网页条目，不碰其它文章）。 */
  deleteSyncedWebPage(urlKey: string): boolean {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || urlKey.length === 0) {
      return false;
    }
    const id: string = 'saved-web|' + urlKey;
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync(
        'SELECT 1 FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE id = ? AND feed_id = ?', [id, WEB_PAGE_FEED_ID]);
      try {
        if (!rs.goToNextRow()) {
          return false;
        }
      } finally {
        rs.close();
      }
      store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE id = ? AND feed_id = ?', [id, WEB_PAGE_FEED_ID]);
      // 索引也要一起删：否则搜索会命中一条已经不存在的网页。
      this.deleteFtsRows([id]);
      this.cjkDeleteRows([id]);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'delete synced web page failed: %{public}d', error.code);
      return false;
    }
  }

  /** 新插入的主条写两张索引（重复项不写：列表与检索都不看它们）。 */
  private indexInserted(item: Article): void {
    const plain: string = this.plainOf(item.plainText, item.content);
    if (this.ftsReady) {
      this.ftsInsert(item.id, item.title, item.summary, plain, item.author);
    }
    // 新装用户首次插入即双写：中文索引与主索引同步维护。
    this.cjkInsert(item.id, item.title, item.summary, plain);
  }

  /**
   * 入库前解析跨源重复：先补齐归一化键，再按批查候选并用 DedupeService 定出主条。
   * 返回 incoming.id → 主条 id；开关关闭 / 查询异常时返回空表（全部按独立文章入库）。
   */
  private resolveCanonicals(articles: Article[]): Map<string, string> {
    const matches: Map<string, string> = new Map<string, string>();
    this.fillDedupeKeys(articles);
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || articles.length === 0 || !appSettings.dedupeEnabled) {
      return matches;
    }
    try {
      const now: number = Date.now();
      const linkKeys: string[] = [];
      const titleKeys: string[] = [];
      const seenLink: Set<string> = new Set<string>();
      const seenTitle: Set<string> = new Set<string>();
      let minAt: number = 0;
      let maxAt: number = 0;
      for (let i = 0; i < articles.length; i += 1) {
        const item: Article = articles[i];
        if (item.linkKey.length > 0 && !seenLink.has(item.linkKey)) {
          seenLink.add(item.linkKey);
          linkKeys.push(item.linkKey);
        }
        if (item.titleKey.length > 0 && !seenTitle.has(item.titleKey)) {
          seenTitle.add(item.titleKey);
          titleKeys.push(item.titleKey);
          const at: number = item.publishedAt > 0 ? item.publishedAt : now;
          if (minAt === 0 || at < minAt) {
            minAt = at;
          }
          if (at > maxAt) {
            maxAt = at;
          }
        }
      }
      const existing: DedupeCandidate[] = [];
      const seenId: Set<string> = new Set<string>();
      this.collectCandidates(store, linkKeys, false, 0, 0, existing, seenId);
      if (titleKeys.length > 0) {
        this.collectCandidates(store, titleKeys, true, minAt - RssConstants.DEDUPE_WINDOW_MS,
          maxAt + RssConstants.DEDUPE_WINDOW_MS, existing, seenId);
      }
      const incoming: DedupeCandidate[] = [];
      for (let i = 0; i < articles.length; i += 1) {
        const item: Article = articles[i];
        // 发布时间缺失（0）时以入库时间为准参与 ±24h 判定。
        const at: number = item.publishedAt > 0 ? item.publishedAt : now;
        incoming.push(new DedupeCandidate(item.id, item.feedId, '', item.linkKey, item.titleKey, at));
      }
      return DedupeService.findMatches(existing, incoming);
    } catch (err) {
      const error: Error = err as Error;
      hilog.warn(DOMAIN, TAG, 'dedupe match failed, degraded to standalone: %{public}s', error.message);
      return new Map<string, string>();
    }
  }

  /** 归一化键始终写入（与开关无关）：关闭后再开启，旧文章仍能并入已有主条。 */
  private fillDedupeKeys(articles: Article[]): void {
    for (let i = 0; i < articles.length; i += 1) {
      const item: Article = articles[i];
      if (item.linkKey.length === 0) {
        item.linkKey = DedupeKeys.urlKey(item.link);
      }
      if (item.titleKey.length === 0) {
        item.titleKey = DedupeKeys.titleKey(item.title);
      }
    }
  }

  /**
   * 批量取已有候选（≤ DEDUPE_KEY_BATCH 个键一批）。
   * byTitle = false 按 link_key 精确匹配；true 按 title_key + 发布时间窗（缺失时间按 0 也纳入，交给内存复核）。
   */
  private collectCandidates(store: relationalStore.RdbStore, keys: string[], byTitle: boolean,
    from: number, to: number, out: DedupeCandidate[], seenId: Set<string>): void {
    for (let start = 0; start < keys.length; start += DEDUPE_KEY_BATCH) {
      const slice: string[] = keys.slice(start, start + DEDUPE_KEY_BATCH);
      const args: Array<relationalStore.ValueType> = [];
      for (let i = 0; i < slice.length; i += 1) {
        args.push(slice[i]);
      }
      let sql: string = 'SELECT id, feed_id, canonical_id, link_key, title_key, published_at FROM ' +
        ArticleDbConstants.TABLE_ARTICLES + ' WHERE ';
      if (byTitle) {
        sql += 'title_key IN (' + placeholders(slice.length) + ')' +
          ' AND (published_at BETWEEN ? AND ? OR published_at = 0)';
        args.push(from);
        args.push(to);
      } else {
        sql += 'link_key IN (' + placeholders(slice.length) + ')';
      }
      const rs: relationalStore.ResultSet = store.querySqlSync(sql, args);
      try {
        while (rs.goToNextRow()) {
          const id: string = rs.getString(rs.getColumnIndex('id'));
          if (id.length === 0 || seenId.has(id)) {
            continue;
          }
          seenId.add(id);
          out.push(new DedupeCandidate(id,
            rs.getString(rs.getColumnIndex('feed_id')),
            rs.getString(rs.getColumnIndex('canonical_id')),
            rs.getString(rs.getColumnIndex('link_key')),
            rs.getString(rs.getColumnIndex('title_key')),
            rs.getLong(rs.getColumnIndex('published_at'))));
        }
      } finally {
        rs.close();
      }
    }
  }

  /**
   * 为已有文章分批补归一化键（升级后旧文章也能作为新文章的合并候选）。
   * 只挑「能算出键」的行（链接 / 标题非空），避免空链接老数据永远被重复选中。
   *
   * @returns 本批处理的条数（调用方按「返回等于 limit 就继续下一批」循环）。
   */
  async backfillDedupeKeys(limit: number): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || limit <= 0) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id, link, title FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE (link_key = \'\' AND link <> \'\') OR (title_key = \'\' AND title <> \'\')' +
        ' LIMIT ?', [Math.max(1, Math.round(limit))]);
      const rows: Array<Array<string>> = [];
      try {
        while (rs.goToNextRow()) {
          rows.push([
            rs.getString(rs.getColumnIndex('id')),
            rs.getString(rs.getColumnIndex('link')),
            rs.getString(rs.getColumnIndex('title'))
          ]);
        }
      } finally {
        rs.close();
      }
      for (let i = 0; i < rows.length; i += 1) {
        store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
          ' SET link_key = ?, title_key = ? WHERE id = ?',
          [DedupeKeys.urlKey(rows[i][1]), DedupeKeys.titleKey(rows[i][2]), rows[i][0]]);
      }
      return rows.length;
    } catch (err) {
      const error: Error = err as Error;
      hilog.warn(DOMAIN, TAG, 'backfill dedupe keys failed: %{public}s', error.message);
      return 0;
    }
  }

  /**
   * 写入远端拉取到的文章与映射（单事务）。
   *
   * - 文章走 INSERT OR IGNORE：本地已存在同 id（同 link）时只补映射，不改正文 / 已读 / 进度；
   * - 只有真正插入的新行才写主 FTS 与中文索引（跨源重复项不写）；
   * - 跨源去重与本地抓取同一套判定（重复项的远端映射照常写入）；
   * - 映射表按 remote_id 覆盖写（重复同步同一篇不会产生多条）。
   *
   * @returns 真正新增的文章条数。
   */
  async insertRemote(articles: Article[], mappings: RemoteMapping[]): Promise<Article[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const created: Article[] = [];
    if (store === undefined || articles.length === 0) {
      return created;
    }
    const byId: Map<string, Article> = new Map<string, Article>();
    for (let i = 0; i < articles.length; i += 1) {
      byId.set(articles[i].id, articles[i]);
    }
    // 与本地抓取同样做跨源去重（远端映射照常写入，重复项也写）。
    const canonicalOf: Map<string, string> = this.resolveCanonicals(articles);
    const now: number = Date.now();
    try {
      store.beginTransaction();
      try {
        for (let i = 0; i < mappings.length; i += 1) {
          const mapping: RemoteMapping = mappings[i];
          const item: Article | undefined = byId.get(mapping.articleId);
          if (item !== undefined) {
            const canonical: string = canonicalOf.get(item.id) ?? '';
            item.canonicalId = canonical;
            store.executeSync(SQL_INSERT, [
              item.id, item.feedId, item.feedTitle, item.title, item.link,
              item.summary, item.content, item.publishedAt,
              item.read ? 1 : 0, item.starred ? 1 : 0, now, item.imageUrl, item.author, item.contentHtml,
              item.linkKey, item.titleKey, canonical
            ]);
            const inserted: boolean = this.lastChanges() > 0;
            if (inserted) {
              // 只有真正新增的行才算「新文章」：规则只对它们执行，重复同步不回溯。
              created.push(item);
              if (canonical.length === 0) {
                this.indexInserted(item);
              }
            }
            byId.delete(mapping.articleId);
          }
          store.executeSync(SQL_UPSERT_REMOTE_MAP,
            [mapping.remoteId, mapping.articleId, mapping.feedId, now]);
        }
        store.commit();
      } catch (inner) {
        store.rollBack();
        throw inner as Error;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'insertRemote failed: %{public}d %{public}s',
        error.code, error.message);
      return [];
    }
    return created;
  }

  /** 拉回远端已读状态：只改状态列，不触碰正文 / 进度 / 标签。 */
  setReadByRemote(id: string, read: boolean): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES + ' SET is_read = ? WHERE id = ?',
      [read ? 1 : 0, id]);
  }

  /** 拉回远端收藏状态：只改状态列，不触碰正文 / 进度 / 标签。 */
  setStarredByRemote(id: string, starred: boolean): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES + ' SET is_starred = ? WHERE id = ?',
      [starred ? 1 : 0, id]);
  }

  /** 批量读取文章状态（拉回远端状态时对比用；按 500 一批避免超长 IN）。 */
  async loadStates(ids: string[]): Promise<ArticleState[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: ArticleState[] = [];
    if (store === undefined || ids.length === 0) {
      return result;
    }
    const chunk: number = 500;
    try {
      for (let start = 0; start < ids.length; start += chunk) {
        const slice: string[] = ids.slice(start, start + chunk);
        const rs: relationalStore.ResultSet = await store.querySql(
          'SELECT id, is_read, is_starred FROM ' + ArticleDbConstants.TABLE_ARTICLES +
          ' WHERE id IN (' + placeholders(slice.length) + ')', slice);
        try {
          while (rs.goToNextRow()) {
            result.push(new ArticleState(
              rs.getString(rs.getColumnIndex('id')),
              rs.getLong(rs.getColumnIndex('is_read')) === 1,
              rs.getLong(rs.getColumnIndex('is_starred')) === 1));
          }
        } finally {
          rs.close();
        }
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'loadStates failed: %{public}d', error.code);
    }
    return result;
  }

  /** 订阅源标题变化时同步到缓存行，列表里的来源名才不会残留旧值。 */
  updateFeedTitle(feedId: string, title: string): void {    this.exec(
      'UPDATE ' + ArticleDbConstants.TABLE_ARTICLES + ' SET feed_title = ? WHERE feed_id = ?',
      [title, feedId]);
  }

  setRead(id: string, read: boolean): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES + ' SET is_read = ? WHERE id = ?',
      [read ? 1 : 0, id]);
  }

  setStarred(id: string, starred: boolean): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES + ' SET is_starred = ? WHERE id = ?',
      [starred ? 1 : 0, id]);
  }

  setSaved(id: string, saved: boolean): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES + ' SET is_saved = ? WHERE id = ?',
      [saved ? 1 : 0, id]);
  }

  /**
   * 批量改状态（多选操作用）。逐条 UPDATE：批量条数是用户一次能选中的量级（几十条），
   * 用 IN (?,?,...) 反而要做占位符拼接，收益不大。
   */
  setReadMany(ids: string[], read: boolean): void {
    for (let i = 0; i < ids.length; i += 1) {
      this.setRead(ids[i], read);
    }
  }

  setStarredMany(ids: string[], starred: boolean): void {
    for (let i = 0; i < ids.length; i += 1) {
      this.setStarred(ids[i], starred);
    }
  }

  setSavedMany(ids: string[], saved: boolean): void {
    for (let i = 0; i < ids.length; i += 1) {
      this.setSaved(ids[i], saved);
    }
  }

  /**
   * 规则隐藏标记：只改展示口径，不删除文章（检索 / 已隐藏列表 / 保留清理都照常）。
   * 与已读 / 收藏一样逐条 UPDATE（批量条数是一次入库的量级，走 IN 拼接收益不大）。
   */
  setHidden(id: string, hidden: boolean): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES + ' SET is_hidden = ? WHERE id = ?',
      [hidden ? 1 : 0, id]);
  }

  setHiddenMany(ids: string[], hidden: boolean): void {
    for (let i = 0; i < ids.length; i += 1) {
      this.setHidden(ids[i], hidden);
    }
  }

  /** 被隐藏文章总数（规则页「已隐藏（N）」入口计数；重复项由主条代表，不单独计数）。 */
  async countHidden(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE is_hidden = 1 AND canonical_id = \'\'');
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'countHidden failed: %{public}d', error.code);
      return 0;
    }
  }

  /** 已隐藏文章（轻量列，按发布时间倒序）：已隐藏列表用，打开时再按需加载正文。 */
  async loadHidden(): Promise<Article[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: Article[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT ' + LIST_COLUMNS + ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a' +
        ' WHERE a.is_hidden = 1 AND a.canonical_id = \'\' ORDER BY a.published_at DESC');
      try {
        while (rs.goToNextRow()) {
          result.push(this.articleFromListRow(rs));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'loadHidden failed: %{public}d', error.code);
    }
    return result;
  }

  /**
   * 批量删除（用户主动删除）：只删列表条目与已缓存正文，**不进回收站**。
   * 同步删除 FTS 行与标签关联，避免检索命中已删除文章 / 残留孤儿关联。
   *
   * 跨源去重：删到主条时先把组内「不在删除列表」的最早成员提为新主条并重指向，
   * 否则整组会跟着主条一起从列表里消失（FR-007 / SC-004）。
   */
  deleteMany(ids: string[]): void {
    if (ids.length === 0) {
      return;
    }
    const promoted: string[] = this.promoteBeforeRemoval(ids);
    this.deleteFtsRows(ids);
    this.cjkDeleteRows(ids);
    this.deleteTagLinks(ids);
    for (let i = 0; i < ids.length; i += 1) {
      this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?', [ids[i]]);
    }
    // 新主条原先作为重复项没有索引，这里补齐（否则它会既在列表里、又搜不到）。
    this.indexManySync(promoted);
  }

  /** 删除一批文章的标签关联（文章真正消失时调用；移入 / 移出回收站不调用）。 */
  private deleteTagLinks(ids: string[]): void {
    if (ids.length === 0) {
      return;
    }
    this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLE_TAGS +
      ' WHERE article_id IN (' + placeholders(ids.length) + ')', ids);
  }

  /**
   * 记录阅读进度（滚动位置，px）—— 下次打开同一篇时恢复。
   * 列类型是 INTEGER，而网页的 window.scrollY 是小数，所以这里取整后再写，
   * 避免存成 REAL 之后读取端类型不匹配。
   */
  setProgress(id: string, progress: number, ratio: number): void {
    const rounded: number = Math.max(0, Math.round(progress));
    const safeRatio: number = Math.min(1, Math.max(0, ratio));
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
      ' SET progress = ?, progress_ratio = ? WHERE id = ?',
      [rounded, safeRatio, id]);
  }

  /**
   * 一次性回填：给「已有提取正文、但还没有纯文本」的老数据补上 plain_text（并补索引）。
   * 只在升级后的头几次启动做有限条数，避免一次性把整库算一遍拖慢启动。
   */
  async backfillPlainText(limit: number): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || limit <= 0) {
      return;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id, reader_html, title, summary, author FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE reader_html <> \'\' AND plain_text = \'\' LIMIT ' + Math.round(limit));
      const rows: Array<Array<string>> = [];
      try {
        while (rs.goToNextRow()) {
          rows.push([
            rs.getString(rs.getColumnIndex('id')),
            rs.getString(rs.getColumnIndex('reader_html')),
            rs.getString(rs.getColumnIndex('title')),
            rs.getString(rs.getColumnIndex('summary')),
            rs.getString(rs.getColumnIndex('author'))
          ]);
        }
      } finally {
        rs.close();
      }
      for (let i = 0; i < rows.length; i += 1) {
        const plain: string = toPlainText(rows[i][1]);
        if (plain.length === 0) {
          continue;
        }
        store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
          ' SET plain_text = ? WHERE id = ?', [plain, rows[i][0]]);
        if (this.ftsReady) {
          this.ftsUpsert(rows[i][0], rows[i][2], rows[i][3], plain, rows[i][4]);
        }
        this.cjkUpsert(rows[i][0], rows[i][2], rows[i][3], plain);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'backfill plain text failed: %{public}d', error.code);
    }
  }

  // ---- 全文检索 ----

  // ---- 回收站（可撤销清理） ----

  /**
   * 移入回收站：事务内「复制到 trash → 删主表 → 删索引」。
   * 返回实际移入条数。
   */
  async archiveToTrash(ids: string[]): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || ids.length === 0) {
      return 0;
    }
    const columns: string = 'id, feed_id, feed_title, title, link, summary, content, published_at,' +
      ' is_read, is_starred, is_saved, is_hidden, fetched_at, image_url, author, progress, progress_ratio,' +
      ' reader_html, content_html, plain_text, page_etag, page_last_modified';
    const now: number = Date.now();
    let moved: number = 0;
    let promoted: string[] = [];
    try {
      store.beginTransaction();
      try {
        // 跨源去重：整组进回收站没问题；只搬主条时先在「不在本批」的成员里提升新主条，
        // 否则留下的重复项会变成指向已消失主条的孤儿（列表里再也看不到）。
        promoted = this.promoteBeforeRemoval(ids);
        for (let i = 0; i < ids.length; i += 1) {
          store.executeSync('INSERT OR REPLACE INTO ' + ArticleDbConstants.TABLE_ARTICLES_TRASH +
            ' (' + columns + ', deleted_at) SELECT ' + columns + ', ? FROM ' +
            ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?', [now, ids[i]]);
          if (this.lastChanges() > 0) {
            moved += 1;
          }
          store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?', [ids[i]]);
        }
        store.commit();
      } catch (inner) {
        store.rollBack();
        throw inner as Error;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'archiveToTrash failed: %{public}d', error.code);
      return 0;
    }
    this.deleteFtsRows(ids);
    this.cjkDeleteRows(ids);
    this.indexManySync(promoted);
    return moved;
  }

  /** 从回收站恢复：事务内搬回主表；恢复后再修正悬挂挂靠并重建索引。返回恢复条数。 */
  async restoreTrash(ids: string[]): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || ids.length === 0) {
      return 0;
    }
    const columns: string = 'id, feed_id, feed_title, title, link, summary, content, published_at,' +
      ' is_read, is_starred, is_saved, is_hidden, fetched_at, image_url, author, progress, progress_ratio,' +
      ' reader_html, content_html, plain_text, page_etag, page_last_modified';
    let restored: number = 0;
    try {
      store.beginTransaction();
      try {
        for (let i = 0; i < ids.length; i += 1) {
          store.executeSync('INSERT OR REPLACE INTO ' + ArticleDbConstants.TABLE_ARTICLES +
            ' (' + columns + ') SELECT ' + columns + ' FROM ' +
            ArticleDbConstants.TABLE_ARTICLES_TRASH + ' WHERE id = ?', [ids[i]]);
          if (this.lastChanges() > 0) {
            restored += 1;
          }
          store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES_TRASH + ' WHERE id = ?', [ids[i]]);
        }
        store.commit();
      } catch (inner) {
        store.rollBack();
        throw inner as Error;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'restoreTrash failed: %{public}d', error.code);
      return 0;
    }
    for (let i = 0; i < ids.length; i += 1) {
      // 主条可能已被删除：挂靠失效时清空 canonical_id 自己当主条，并补索引；仍是重复项则不建索引。
      const needsIndex: boolean = this.repairAfterRestore(ids[i]);
      if (needsIndex && (this.ftsReady || this.cjkReady)) {
        await this.indexOne(ids[i]);
      }
    }
    return restored;
  }

  /**
   * 恢复后修正挂靠关系：canonical_id 指向的主条不存在时清空（自己成为主条）。
   * @returns 是否需要为这条重建索引（= 它是主条）。
   */
  private repairAfterRestore(id: string): boolean {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return false;
    }
    try {
      const canonical: string = this.canonicalOfSync(store, id);
      if (canonical.length === 0) {
        return true;
      }
      if (this.rowExistsSync(store, canonical)) {
        return false;
      }
      store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
        ' SET canonical_id = \'\' WHERE id = ?', [id]);
      hilog.info(DOMAIN, TAG, 'restored article detached from missing canonical');
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'repair after restore failed: %{public}d', error.code);
      return false;
    }
  }

  /** 恢复后按主表内容重建单条索引。 */
  private async indexOne(id: string): Promise<void> {
    this.indexOneSync(id);
  }

  /** indexOne 的同步实现（删除 / 回收站等同步路径里补索引用）。 */
  private indexOneSync(id: string): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || (!this.ftsReady && !this.cjkReady)) {
      return;
    }
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync(
        'SELECT title, summary, plain_text, author FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?',
        [id]);
      try {
        if (rs.goToNextRow()) {
          const title: string = rs.getString(rs.getColumnIndex('title'));
          const summary: string = rs.getString(rs.getColumnIndex('summary'));
          const plain: string = rs.getString(rs.getColumnIndex('plain_text'));
          if (this.ftsReady) {
            this.ftsUpsert(id, title, summary, plain, rs.getString(rs.getColumnIndex('author')));
          }
          this.cjkUpsert(id, title, summary, plain);
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'index restored article failed: %{public}d', error.code);
    }
  }

  /** 批量补索引（主条提升后调用；索引不可用时整体跳过）。 */
  private indexManySync(ids: string[]): void {
    if (ids.length === 0 || (!this.ftsReady && !this.cjkReady)) {
      return;
    }
    for (let i = 0; i < ids.length; i += 1) {
      this.indexOneSync(ids[i]);
    }
  }

  // ---- 跨源去重：主条提升 / 组查询 ----

  /**
   * 删除 / 清理前的组内主条提升。
   *
   * 对每个即将离开主表的**主条**：在「不在本次离开列表」的成员里选最早入库者提升为主条
   * （canonical_id 置空 + 稍后补索引），其余成员改指向新主条；没有剩余成员时不动
   * （成员都在离开列表里，本来就随主条一起消失，组自然解散）。
   *
   * @returns 被提升为主条的 id（调用方负责补 FTS / 中文索引）。
   */
  private promoteBeforeRemoval(ids: string[]): string[] {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || ids.length === 0) {
      return [];
    }
    const removing: Set<string> = new Set<string>();
    const roots: string[] = [];
    try {
      // 一次查出本批的挂靠状态：只有 canonical_id 为空的主条才需要提升。
      for (let start = 0; start < ids.length; start += DEDUPE_KEY_BATCH) {
        const slice: string[] = ids.slice(start, start + DEDUPE_KEY_BATCH);
        for (let i = 0; i < slice.length; i += 1) {
          removing.add(slice[i]);
        }
        const rs: relationalStore.ResultSet = store.querySqlSync(
          'SELECT id, canonical_id FROM ' + ArticleDbConstants.TABLE_ARTICLES +
          ' WHERE id IN (' + placeholders(slice.length) + ')', slice);
        try {
          while (rs.goToNextRow()) {
            if (rs.getString(rs.getColumnIndex('canonical_id')).length === 0) {
              roots.push(rs.getString(rs.getColumnIndex('id')));
            }
          }
        } finally {
          rs.close();
        }
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'promote prepare failed: %{public}d', error.code);
      return [];
    }
    return this.promoteRoots(store, roots, removing);
  }

  /** 给定「即将离开的主条」与「一起离开的 id 集合」，逐组提升 + 重指向。 */
  private promoteRoots(store: relationalStore.RdbStore, roots: string[],
    removing: Set<string>): string[] {
    const promoted: string[] = [];
    if (roots.length === 0) {
      return promoted;
    }
    try {
      // 按批取出这些主条的成员：几千条清理也只需要十几次查询。
      const membersByRoot: Map<string, DedupeCandidate[]> = new Map<string, DedupeCandidate[]>();
      for (let start = 0; start < roots.length; start += DEDUPE_KEY_BATCH) {
        const slice: string[] = roots.slice(start, start + DEDUPE_KEY_BATCH);
        const rs: relationalStore.ResultSet = store.querySqlSync(
          'SELECT id, feed_id, canonical_id, link_key, title_key, published_at FROM ' +
          ArticleDbConstants.TABLE_ARTICLES +
          ' WHERE canonical_id IN (' + placeholders(slice.length) + ')', slice);
        try {
          while (rs.goToNextRow()) {
            const root: string = rs.getString(rs.getColumnIndex('canonical_id'));
            const candidate: DedupeCandidate = new DedupeCandidate(
              rs.getString(rs.getColumnIndex('id')),
              rs.getString(rs.getColumnIndex('feed_id')),
              root,
              rs.getString(rs.getColumnIndex('link_key')),
              rs.getString(rs.getColumnIndex('title_key')),
              rs.getLong(rs.getColumnIndex('published_at')));
            const bucket: DedupeCandidate[] | undefined = membersByRoot.get(root);
            if (bucket === undefined) {
              membersByRoot.set(root, [candidate]);
            } else {
              bucket.push(candidate);
            }
          }
        } finally {
          rs.close();
        }
      }
      for (let i = 0; i < roots.length; i += 1) {
        const root: string = roots[i];
        const members: DedupeCandidate[] | undefined = membersByRoot.get(root);
        const remaining: DedupeCandidate[] = [];
        if (members !== undefined) {
          for (let j = 0; j < members.length; j += 1) {
            if (!removing.has(members[j].id)) {
              remaining.push(members[j]);
            }
          }
        }
        const nextRoot: string = DedupeService.pickPromotion(remaining);
        if (nextRoot.length === 0) {
          continue;
        }
        store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
          ' SET canonical_id = \'\' WHERE id = ?', [nextRoot]);
        store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
          ' SET canonical_id = ? WHERE canonical_id = ? AND id <> ?', [nextRoot, root, nextRoot]);
        promoted.push(nextRoot);
        hilog.info(DOMAIN, TAG, 'canonical promoted, group size=%{public}d',
          remaining.length + 1);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'promote canonical failed: %{public}d', error.code);
    }
    return promoted;
  }

  /** 读一条文章的 canonical_id（不存在返回空串）。 */
  private canonicalOfSync(store: relationalStore.RdbStore, id: string): string {
    const rs: relationalStore.ResultSet = store.querySqlSync(
      'SELECT canonical_id FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?', [id]);
    try {
      return rs.goToNextRow() ? rs.getString(rs.getColumnIndex('canonical_id')) : '';
    } finally {
      rs.close();
    }
  }

  /** 某篇文章是否还在主表里。 */
  private rowExistsSync(store: relationalStore.RdbStore, id: string): boolean {
    const rs: relationalStore.ResultSet = store.querySqlSync(
      'SELECT 1 AS ok FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?', [id]);
    try {
      return rs.goToNextRow();
    } finally {
      rs.close();
    }
  }

  /**
   * 组内全部 id：主条 + 全部重复项，按发布时间升序（最早入库的在前）。
   * 传入的若是重复项，先解析到根主条；查不到时退回 [id]（幂等，不抛错）。
   */
  async groupIdsOf(id: string): Promise<string[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: string[] = [];
    if (store === undefined || id.length === 0) {
      return result;
    }
    try {
      const root: string = await this.rootOf(store, id);
      const args: Array<relationalStore.ValueType> = [root, root];
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE id = ? OR canonical_id = ? ORDER BY published_at ASC, id ASC', args);
      try {
        while (rs.goToNextRow()) {
          result.push(rs.getString(rs.getColumnIndex('id')));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'groupIdsOf failed: %{public}d', error.code);
      return [id];
    }
    if (result.length === 0) {
      result.push(id);
    }
    return result;
  }

  /** 组内来源清单（详情页来源区用）：按发布时间升序，主条在前面的概率更高。 */
  async loadGroupSources(articleId: string): Promise<GroupSource[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: GroupSource[] = [];
    if (store === undefined || articleId.length === 0) {
      return result;
    }
    try {
      const root: string = await this.rootOf(store, articleId);
      const args: Array<relationalStore.ValueType> = [root, root];
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id, feed_title, link, published_at FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE id = ? OR canonical_id = ? ORDER BY published_at ASC, id ASC', args);
      try {
        while (rs.goToNextRow()) {
          result.push(new GroupSource(
            rs.getString(rs.getColumnIndex('id')),
            rs.getString(rs.getColumnIndex('feed_title')),
            rs.getString(rs.getColumnIndex('link')),
            rs.getLong(rs.getColumnIndex('published_at'))));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'loadGroupSources failed: %{public}d', error.code);
    }
    return result;
  }

  /** 解析根主条：沿 canonical_id 逐跳上溯，最多 8 跳（防御脏数据造成的环）。 */
  private async rootOf(store: relationalStore.RdbStore, id: string): Promise<string> {
    let current: string = id;
    for (let depth = 0; depth < 8; depth += 1) {
      const args: Array<relationalStore.ValueType> = [current];
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT canonical_id FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?', args);
      let next: string = '';
      let found: boolean = false;
      try {
        found = rs.goToNextRow();
        if (found) {
          next = rs.getString(rs.getColumnIndex('canonical_id'));
        }
      } finally {
        rs.close();
      }
      if (!found || next.length === 0 || next === current) {
        break;
      }
      current = next;
    }
    return current;
  }

  /** 清理过期回收站条目（deleted_at < beforeTs）；这些文章真正消失，标签关联一并清理。 */
  async purgeTrash(beforeTs: number): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    try {
      // 先取 id：关联表在事务外按 id 批量删除，避免留下孤儿标签关联。
      const ids: string[] = [];
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id FROM ' + ArticleDbConstants.TABLE_ARTICLES_TRASH + ' WHERE deleted_at < ?', [beforeTs]);
      try {
        while (rs.goToNextRow()) {
          ids.push(rs.getString(rs.getColumnIndex('id')));
        }
      } finally {
        rs.close();
      }
      const count: number = ids.length;
      await store.executeSql('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES_TRASH +
        ' WHERE deleted_at < ?', [beforeTs]);
      this.deleteTagLinks(ids);
      return count;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'purgeTrash failed: %{public}d', error.code);
      return 0;
    }
  }

  /** 回收站条数。 */
  async trashCount(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    try {
      return await this.queryCount(store,
        'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_ARTICLES_TRASH, []);
    } catch (err) {
      return 0;
    }
  }

  /** 回收站里全部 id（恢复全部用）。 */
  async trashIds(): Promise<string[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const ids: string[] = [];
    if (store === undefined) {
      return ids;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id FROM ' + ArticleDbConstants.TABLE_ARTICLES_TRASH + ' ORDER BY deleted_at DESC');
      try {
        while (rs.goToNextRow()) {
          ids.push(rs.getString(rs.getColumnIndex('id')));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'trashIds failed: %{public}d', error.code);
    }
    return ids;
  }

  // ---- 保留清理候选 / 统计 ----

  /**
   * 保留清理候选：已排除收藏、稍后读、含高亮、以及调用方指定的保护 id（当前打开文章）。
   *
   * @param mode       保留模式（forever / days / unread）
   * @param days       全局保留天数
   * @param feedDays   源级覆盖天数（feedId → 天数；0 = 永久）
   * @param protectedIds 额外保护的文章 id（当前打开的文章等）
   */
  async retentionCandidates(mode: string, days: number,
    feedDays: Map<string, number>, protectedIds: string[]): Promise<RetentionCandidate[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: RetentionCandidate[] = [];
    if (store === undefined) {
      return result;
    }
    // 全局永久保留、且没有任何源级覆盖时，没有任何可清理项。
    if (mode === RetentionMode.FOREVER && feedDays.size === 0) {
      return result;
    }
    try {
      // SQL 先粗筛（收藏 / 稍后读 / 有高亮的直接排除），再在内存里按策略复核。
      // 重复项不直接清理：它们随主条一起被清，或等主条提升后再变成可清理的主条。
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT a.id, a.feed_id, a.published_at, a.is_read, a.is_starred, a.is_saved FROM ' +
        ArticleDbConstants.TABLE_ARTICLES + ' a' +
        ' WHERE a.is_starred = 0 AND a.is_saved = 0 AND a.canonical_id = \'\'' +
        ' AND NOT EXISTS (SELECT 1 FROM ' + ArticleDbConstants.TABLE_HIGHLIGHTS +
        ' h WHERE h.article_id = a.id)');
      const now: number = Date.now();
      try {
        while (rs.goToNextRow()) {
          const id: string = rs.getString(rs.getColumnIndex('id'));
          if (protectedIds.indexOf(id) >= 0) {
            continue;
          }
          const starred: boolean = rs.getLong(rs.getColumnIndex('is_starred')) === 1;
          const saved: boolean = rs.getLong(rs.getColumnIndex('is_saved')) === 1;
          const feedId: string = rs.getString(rs.getColumnIndex('feed_id'));
          const publishedAt: number = rs.getLong(rs.getColumnIndex('published_at'));
          const read: boolean = rs.getLong(rs.getColumnIndex('is_read')) === 1;
          // 双重保险：即使 SQL 条件将来被改动，纯规则也会再挡一次（含「当前打开文章」）。
          if (RetentionPolicy.isProtected(starred, saved, 0, protectedIds.length > 0 ? protectedIds[0] : '', id)) {
            continue;
          }
          if (mode === RetentionMode.UNREAD) {
            if (RetentionPolicy.isUnreadModeCandidate(read)) {
              result.push(new RetentionCandidate(id, feedId, publishedAt, read));
            }
            continue;
          }
          const override: number | undefined = feedDays.get(feedId);
          // 源级覆盖优先；否则全局 forever 表示该源永久保留，days 模式取全局天数。
          const effective: number = override !== undefined ? override
            : (mode === RetentionMode.FOREVER ? 0 : days);
          if (RetentionPolicy.isOlderThan(publishedAt, effective, now)) {
            result.push(new RetentionCandidate(id, feedId, publishedAt, read));
          }
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'retentionCandidates failed: %{public}d', error.code);
    }
    return result;
  }

  /**
   * 存储统计：总条数 / 文本占用 / 按源占用 / 回收站条数。
   * cleanableCount 由 RetentionService 估算后传入（默认 0 表示尚未计算）。
   */
  async storageStats(cleanableCount: number = 0): Promise<StorageStats> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return StorageStats.empty();
    }
    let articleCount: number = 0;
    let textBytes: number = 0;
    const perFeed: FeedStorageStat[] = [];
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS n,' +
        ' COALESCE(SUM(LENGTH(reader_html) + LENGTH(content_html) + LENGTH(plain_text)), 0) AS bytes' +
        ' FROM ' + ArticleDbConstants.TABLE_ARTICLES);
      try {
        if (rs.goToNextRow()) {
          articleCount = rs.getLong(rs.getColumnIndex('n'));
          textBytes = rs.getLong(rs.getColumnIndex('bytes'));
        }
      } finally {
        rs.close();
      }
      const feedRs: relationalStore.ResultSet = await store.querySql(
        'SELECT feed_id, MAX(feed_title) AS title, COUNT(*) AS n,' +
        ' COALESCE(SUM(LENGTH(reader_html) + LENGTH(content_html) + LENGTH(plain_text)), 0) AS bytes' +
        ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' GROUP BY feed_id ORDER BY bytes DESC');
      try {
        while (feedRs.goToNextRow()) {
          perFeed.push(new FeedStorageStat(
            feedRs.getString(feedRs.getColumnIndex('feed_id')),
            feedRs.getString(feedRs.getColumnIndex('title')),
            feedRs.getLong(feedRs.getColumnIndex('n')),
            feedRs.getLong(feedRs.getColumnIndex('bytes'))));
        }
      } finally {
        feedRs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'storageStats failed: %{public}d', error.code);
    }
    const trash: number = await this.trashCount();
    return new StorageStats(articleCount, textBytes, perFeed, cleanableCount, trash);
  }

  /** 正文缓存占用：缓存过的条数与字符总量（设置页展示用）。 */
  async cacheStats(): Promise<CacheStats> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return new CacheStats(0, 0);
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS n, COALESCE(SUM(LENGTH(reader_html) + LENGTH(content_html) + LENGTH(plain_text)), 0) AS bytes' +
        ' FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE reader_html <> \'\' OR content_html <> \'\' OR plain_text <> \'\'');
      try {
        if (rs.goToNextRow()) {
          return new CacheStats(rs.getLong(rs.getColumnIndex('n')), rs.getLong(rs.getColumnIndex('bytes')));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cache stats failed: %{public}d', error.code);
    }
    return new CacheStats(0, 0);
  }

  /** 已保存 Reader 正文的实际 UTF-8 字节数，包含内嵌图片。 */
  async offlineCacheBytes(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COALESCE(SUM(LENGTH(CAST(reader_html AS BLOB))), 0) AS bytes FROM ' +
        ArticleDbConstants.TABLE_ARTICLES + ' WHERE reader_html <> \'\'');
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('bytes')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'offline cache size failed: %{public}d', error.code);
      return 0;
    }
  }

  /** 仅移除单篇 Reader 离线文件；保留 feed 正文、检索文本和阅读状态。 */
  async clearOfflineArticle(id: string): Promise<boolean> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || id.length === 0) {
      return false;
    }
    try {
      await store.executeSql('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
        ' SET reader_html = \'\' WHERE id = ?', [id]);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'clear offline article failed: %{public}d', error.code);
      return false;
    }
  }

  /**
   * 清理正文缓存：清空未收藏文章的 reader_html / content_html / plain_text，
   * 列表条目与已读状态保留（收藏的文章不动）。返回清理条数。
   */
  async clearCachedContent(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    try {
      let affected: number = 0;
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS n FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE is_starred = 0 AND (reader_html <> \'\' OR content_html <> \'\' OR plain_text <> \'\')');
      try {
        if (rs.goToNextRow()) {
          affected = rs.getLong(rs.getColumnIndex('n'));
        }
      } finally {
        rs.close();
      }
      await store.executeSql(
        'UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
        ' SET reader_html = \'\', content_html = \'\', plain_text = \'\'' +
        ' WHERE is_starred = 0 AND (reader_html <> \'\' OR content_html <> \'\' OR plain_text <> \'\')');
      hilog.info(DOMAIN, TAG, 'cleared cached content rows: %{public}d', affected);
      return affected;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'clear cache failed: %{public}d', error.code);
      return 0;
    }
  }

  /** 写入正文页的两个校验器（条件请求用）。 */
  setPageValidators(id: string, etag: string, lastModified: string): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
      ' SET page_etag = ?, page_last_modified = ? WHERE id = ?',
      [etag, lastModified, id]);
  }

  /** 写入 Reader 视图的结构化正文 HTML（离线阅读用）与其纯文本（检索 / 复制 / 朗读用）；同步两张索引。 */
  setReaderHtml(id: string, html: string, plainText: string): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
      ' SET reader_html = ?, plain_text = ? WHERE id = ?',
      [html, plainText, id]);
    if (this.ftsReady || this.cjkReady) {
      this.upsertIndexFromRow(id, plainText);
    }
  }

  /** 用主表当前值刷新索引（setReaderHtml 后调用：title / summary / author 没变，只换纯文本）。 */
  private upsertIndexFromRow(id: string, plainText: string): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync(
        'SELECT title, summary, author FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?', [id]);
      try {
        if (rs.goToNextRow()) {
          const title: string = rs.getString(rs.getColumnIndex('title'));
          const summary: string = rs.getString(rs.getColumnIndex('summary'));
          if (this.ftsReady) {
            this.ftsUpsert(id, title, summary, plainText, rs.getString(rs.getColumnIndex('author')));
          }
          // 正文提取完成后覆盖插入时用 content 生成的旧 grams。
          this.cjkUpsert(id, title, summary, plainText);
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'upsert index failed: %{public}d', error.code);
    }
  }

  /**
   * 一次性回填列表摘要：用当前清洗规则重算库里已有的摘要，只写「结果有变化」的行（幂等）。
   * 不重新抓 feed —— 摘要清洗（去 CTA 尾巴、标题复读、链接堆抑制）只依赖已存的 title + summary。
   */
  async resummarizeAll(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    const fixes: SummaryFix[] = [];
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id, title, summary FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE summary <> \'\'');
      try {
        while (rs.goToNextRow()) {
          const id: string = rs.getString(rs.getColumnIndex('id'));
          const title: string = rs.getString(rs.getColumnIndex('title'));
          const old: string = rs.getString(rs.getColumnIndex('summary'));
          const next: string = summarizeForList(old, title, RssConstants.SUMMARY_MAX_CHARS);
          if (next !== old) {
            fixes.push(new SummaryFix(id, next));
          }
        }
      } finally {
        rs.close();
      }
      for (let i = 0; i < fixes.length; i += 1) {
        this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
          ' SET summary = ? WHERE id = ?', [fixes[i].summary, fixes[i].id]);
        this.reindexRow(fixes[i].id);
      }
      hilog.info(DOMAIN, TAG, 'resummarize updated rows: %{public}d', fixes.length);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'resummarize failed: %{public}d', error.code);
      return -1;
    }
    return fixes.length;
  }

  /** 按主表当前值重建某行的两套检索索引（摘要变更后 grams 也要重算）。 */
  private reindexRow(id: string): void {
    if (!this.ftsReady && !this.cjkReady) {
      return;
    }
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync(
        'SELECT title, summary, plain_text, author FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?',
        [id]);
      try {
        if (rs.goToNextRow()) {
          const title: string = rs.getString(rs.getColumnIndex('title'));
          const summary: string = rs.getString(rs.getColumnIndex('summary'));
          const plain: string = rs.getString(rs.getColumnIndex('plain_text'));
          this.ftsUpsert(id, title, summary, plain, rs.getString(rs.getColumnIndex('author')));
          this.cjkUpsert(id, title, summary, plain);
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'reindex after resummarize failed: %{public}d', error.code);
    }
  }

  markAllRead(): void {    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES + ' SET is_read = 1 WHERE is_read = 0', []);
  }

  /** 删除订阅源及其文章（含索引与标签关联）。 */
  deleteByFeed(feedId: string): void {
    // 跨源去重：本源的「主条」可能在别的源还有成员，删源前先提升，否则那些成员会变成孤儿重复项。
    const roots: string[] = [];
    const removing: Set<string> = new Set<string>();
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store !== undefined) {
      try {
        const rs: relationalStore.ResultSet = store.querySqlSync(
          'SELECT id, canonical_id FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE feed_id = ?', [feedId]);
        try {
          while (rs.goToNextRow()) {
            const id: string = rs.getString(rs.getColumnIndex('id'));
            removing.add(id);
            if (rs.getString(rs.getColumnIndex('canonical_id')).length === 0) {
              roots.push(id);
            }
          }
        } finally {
          rs.close();
        }
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'deleteByFeed prepare failed: %{public}d', error.code);
      }
    }
    const promoted: string[] = store === undefined ? [] : this.promoteRoots(store, roots, removing);
    if (this.ftsReady) {
      this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS +
        ' WHERE article_id IN (SELECT id FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE feed_id = ?)',
        [feedId]);
    }
    if (this.cjkReady) {
      this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK +
        ' WHERE article_id IN (SELECT id FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE feed_id = ?)',
        [feedId]);
    }
    this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLE_TAGS +
      ' WHERE article_id IN (SELECT id FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE feed_id = ?)',
      [feedId]);
    this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE feed_id = ?', [feedId]);
    this.indexManySync(promoted);
  }

  /**
   * 旧「1000 篇上限」入口：已废弃。
   * 保留空实现是为了兼容仍在调用它的编排层 —— 保留策略现在由 RetentionService 负责，
   * 抓取后不再按固定条数删除任何历史。
   */
  prune(): void {
    // no-op：固定条数上限已移除。
  }

  // ---- 备份 / 迁移 ----
  //
  // 只做数据搬运：导出取全量元数据，导入按主键并集（不删任何本地数据）。
  // 导入不写 FTS / 中文索引 —— 由 BackupService 在整次导入结束后统一重建，
  // 避免逐条建索引拖慢导入，也避免重复项占索引。
  // 所有方法失败时只记日志并返回 0 / 空数组，不向调用方抛异常。

  /** 导出文章段（仅元数据 + 阅读状态列，不含正文缓存）。 */
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

  /**
   * 导入文章段：分批事务 + 状态并集（幂等）。
   *
   * - `validFeedIds`：本次导入后确实存在的订阅 id 集合。订阅在 preferences 里，本库没有 feeds 表，
   *   所以由 BackupService 传入；不在集合里的文章计入 skipped（不报错、不中断）。
   * - 已存在：`mergeArticleState` 决定并集后的状态（读 / 收藏 / 稍后读 / 隐藏 OR、进度 max、
   *   canonicalId 保留本地非空值），只 UPDATE 状态列，不覆盖标题 / 正文。
   * - 不存在：整行 INSERT（正文列留空，首次打开时重新提取），状态取备份值。
   * - 单个批次失败只回滚该批次并记日志，已提交的批次保留；返回值只统计已提交的部分。
   */
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

  /** 读已有文章的状态列；不存在返回 undefined（同步查询，事务内不会被其它等待打断）。 */
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
