/*
 * ArticleStore.ets — 文章本地缓存（Model 层：屏蔽 @ohos.data.relationalStore）。
 *
 * 缓存的意义有两个：
 *   1. 离线阅读 —— 冷启动先出缓存列表，再去联网刷新；
 *   2. 已读 / 收藏持久化 —— 这两项只存在于本地库，抓取时绝不覆盖（见 insertNew 只做 INSERT OR IGNORE）。
 * 时间统一存毫秒时间戳；布尔用 0/1。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { ArticleDbConstants, ReaderState } from '../common/constants/RssConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'ArticleStore';

const SQL_CREATE: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_ARTICLES + ' (' +
  'id TEXT PRIMARY KEY, ' +
  'feed_id TEXT NOT NULL, ' +
  'feed_title TEXT NOT NULL DEFAULT \'\', ' +
  'title TEXT NOT NULL DEFAULT \'\', ' +
  'link TEXT NOT NULL DEFAULT \'\', ' +
  'summary TEXT NOT NULL DEFAULT \'\', ' +
  'content TEXT NOT NULL DEFAULT \'\', ' +
  'published_at INTEGER NOT NULL DEFAULT 0, ' +
  'is_read INTEGER NOT NULL DEFAULT 0, ' +
  'is_starred INTEGER NOT NULL DEFAULT 0, ' +
  'fetched_at INTEGER NOT NULL DEFAULT 0, ' +
  'image_url TEXT NOT NULL DEFAULT \'\', ' +
  'author TEXT NOT NULL DEFAULT \'\', ' +
  'progress INTEGER NOT NULL DEFAULT 0, ' +
  'progress_ratio REAL NOT NULL DEFAULT 0, ' +
  'reader_html TEXT NOT NULL DEFAULT \'\')';

/** 老库补列（表已存在时 CREATE 不会加列，ALTER 失败可忽略）。 */
const SQL_ADD_IMAGE: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN image_url TEXT NOT NULL DEFAULT \'\'';
const SQL_ADD_AUTHOR: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN author TEXT NOT NULL DEFAULT \'\'';
/** 阅读进度（滚动位置，px）。 */
const SQL_ADD_PROGRESS: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN progress INTEGER NOT NULL DEFAULT 0';
/** 阅读进度比例（0–1）：换排版后恢复位置用。 */
const SQL_ADD_PROGRESS_RATIO: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN progress_ratio REAL NOT NULL DEFAULT 0';
/** Reader 视图的结构化正文 HTML（提取 + 净化后）。 */
const SQL_ADD_READER: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN reader_html TEXT NOT NULL DEFAULT \'\'';

const SQL_INSERT: string =
  'INSERT OR IGNORE INTO ' + ArticleDbConstants.TABLE_ARTICLES +
  ' (id, feed_id, feed_title, title, link, summary, content, published_at, is_read, is_starred, fetched_at,' +
  ' image_url, author) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

const SQL_SELECT_ALL: string =
  'SELECT id, feed_id, feed_title, title, link, summary, content, published_at, is_read, is_starred,' +
  ' image_url, author, progress, progress_ratio, reader_html' +
  ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' ORDER BY published_at DESC';

/** 卡片展示用的轻量快照：未读数 + 最新几条标题（不把整库读进内存）。 */
export class WidgetSnapshot {
  readonly unread: number;
  readonly titles: string[];

  constructor(unread: number, titles: string[]) {
    this.unread = unread;
    this.titles = titles;
  }
}

export class ArticleStore {
  private store: relationalStore.RdbStore | undefined = undefined;

  /** 打开（必要时建表）本地库。失败时降级为「无缓存」而不是崩溃。 */
  async open(context: common.Context): Promise<void> {
    try {
      const config: relationalStore.StoreConfig = {
        name: ArticleDbConstants.DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      this.store = await relationalStore.getRdbStore(context, config);
      this.store.executeSync(SQL_CREATE);
      this.addColumnIfNeeded(SQL_ADD_IMAGE);
      this.addColumnIfNeeded(SQL_ADD_AUTHOR);
      this.addColumnIfNeeded(SQL_ADD_PROGRESS);
      this.addColumnIfNeeded(SQL_ADD_PROGRESS_RATIO);
      this.addColumnIfNeeded(SQL_ADD_READER);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'open failed: %{public}d', error.code);
      this.store = undefined;
    }
  }

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
      return new WidgetSnapshot(0, []);
    }
    let unread: number = 0;
    const titles: string[] = [];
    try {
      const countRs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE is_read = 0');
      try {
        unread = countRs.goToNextRow() ? countRs.getLong(countRs.getColumnIndex('c')) : 0;
      } finally {
        countRs.close();
      }
      const titleRs: relationalStore.ResultSet = await store.querySql(
        'SELECT title FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' ORDER BY published_at DESC LIMIT ?', [limit]);
      try {
        while (titleRs.goToNextRow() && titles.length < limit) {
          titles.push(titleRs.getString(titleRs.getColumnIndex('title')));
        }
      } finally {
        titleRs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'widgetSnapshot failed: %{public}d', error.code);
    }
    return new WidgetSnapshot(unread, titles);
  }

  /** 读取本地缓存（按发布时间倒序）。 */
  async loadRecent(): Promise<Article[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: Article[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(SQL_SELECT_ALL);
      try {
        while (rs.goToNextRow()) {
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
          // 用 getDouble 读：老数据里可能残留小数（列是 INTEGER，但 SQLite 动态类型允许 REAL）。
          article.progress = rs.getDouble(rs.getColumnIndex('progress'));
          article.progressRatio = rs.getDouble(rs.getColumnIndex('progress_ratio'));
          article.readerHtml = rs.getString(rs.getColumnIndex('reader_html'));
          if (article.readerHtml.length > 0) {
            article.readerState = ReaderState.READY;
          }
          result.push(article);
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'loadRecent failed: %{public}d', error.code);
    }
    return result;
  }

  /** 入库新抓到的文章：只插入不存在的行，已有行的已读 / 收藏状态保持不变。 */
  insertNew(articles: Article[]): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || articles.length === 0) {
      return;
    }
    const now: number = Date.now();
    try {
      store.beginTransaction();
      try {
        for (let i = 0; i < articles.length; i += 1) {
          const item: Article = articles[i];
          store.executeSync(SQL_INSERT, [
            item.id, item.feedId, item.feedTitle, item.title, item.link,
            item.summary, item.content, item.publishedAt,
            item.read ? 1 : 0, item.starred ? 1 : 0, now, item.imageUrl, item.author
          ]);
        }
        store.commit();
      } catch (inner) {
        store.rollBack();
        throw inner as Error;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'insertNew failed: %{public}d', error.code);
    }
  }

  /** 订阅源标题变化时同步到缓存行，列表里的来源名才不会残留旧值。 */
  updateFeedTitle(feedId: string, title: string): void {
    this.exec(
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

  /** 写入 Reader 视图的结构化正文 HTML（离线阅读用）。 */
  setReaderHtml(id: string, html: string): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES + ' SET reader_html = ? WHERE id = ?',
      [html, id]);
  }

  markAllRead(): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES + ' SET is_read = 1 WHERE is_read = 0', []);
  }

  deleteByFeed(feedId: string): void {
    this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE feed_id = ?', [feedId]);
  }

  /** 缓存上限：清理最旧的未收藏文章。 */
  prune(): void {
    this.exec(
      'DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES +
      ' WHERE is_starred = 0 AND id NOT IN (' +
      ' SELECT id FROM ' + ArticleDbConstants.TABLE_ARTICLES +
      ' ORDER BY published_at DESC LIMIT ?)',
      [ArticleDbConstants.MAX_CACHED_ARTICLES]);
  }

  /** 只为老库补列：列已存在时 executeSync 会抛错，这里静默处理。 */
  private addColumnIfNeeded(sql: string): void {
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

  private exec(sql: string, args: Array<relationalStore.ValueType>): void {
    const store: relationalStore.RdbStore | undefined = this.store;
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

/** 全局唯一实例。 */
export const articleStore: ArticleStore = new ArticleStore();
