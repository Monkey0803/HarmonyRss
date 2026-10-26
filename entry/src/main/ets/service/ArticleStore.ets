/*
 * ArticleStore.ets — 文章本地库（Model 层：屏蔽 @ohos.data.relationalStore）。
 *
 * 数据职责：
 *   1. 离线阅读 —— 冷启动先出缓存列表（轻量列），正文按需加载；
 *   2. 已读 / 收藏 / 稍后读 / 进度持久化 —— 抓取时绝不覆盖（INSERT OR IGNORE）；
 *   3. 全文检索 —— 两张 FTS5 虚表同步写入：主索引（标题/摘要/正文/作者，纯英文查询用）与
 *      中文二元组索引（含中文的查询一律走它），任一不可用或查询失败降级为 LIKE；
 *   4. 可撤销清理 —— 清理先进回收站（articles_trash），7 天内可恢复。
 *
 * 结构迁移用 RdbStore.version 显式版本化（v1 = 初始表；v2 = 索引 + FTS + 回收站；
 * v3 = 中文检索索引），旧库缺列仍用 ALTER 兼容；迁移失败不删库，降级为「无缓存 / 无检索」继续运行。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
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
import { escapeFtsToken } from './SearchQueryParser';
import { compile, hasCjk, isBlankQuery, postFilterSql } from './SearchPlan';
import { grams } from './CjkTokenizer';
import { DedupeKeys } from './DedupeKeys';
import { DedupeService } from './DedupeService';

const DOMAIN: number = 0x0000;
const TAG: string = 'ArticleStore';

/** 正文相关列（列表不读，按需 loadBody）。 */
const BODY_COLUMNS: string =
  'content, content_html, reader_html, plain_text, page_etag, page_last_modified';

/** 轻量列表列：不含任何正文 HTML / 纯文本。列名带 `a.` 前缀，调用方一律 `FROM articles a`。 */
const LIST_COLUMNS: string =
  'a.id, a.feed_id, a.feed_title, a.title, a.link, a.summary, a.published_at, a.is_read, a.is_starred, a.is_saved,' +
  ' a.is_hidden, a.image_url, a.author, a.progress, a.progress_ratio,' +
  ' (CASE WHEN a.reader_html <> \'\' THEN 1 ELSE 0 END) AS has_reader,' +
  ' a.canonical_id,' +
  // 组内来源数（含主条自己）：主条列表行据此显示「N 个来源」。
  ' (SELECT COUNT(*) FROM ' + ArticleDbConstants.TABLE_ARTICLES +
  ' d WHERE d.canonical_id = a.id) AS dup_count';

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
  'is_saved INTEGER NOT NULL DEFAULT 0, ' +
  'is_hidden INTEGER NOT NULL DEFAULT 0, ' +
  'fetched_at INTEGER NOT NULL DEFAULT 0, ' +
  'image_url TEXT NOT NULL DEFAULT \'\', ' +
  'author TEXT NOT NULL DEFAULT \'\', ' +
  'progress INTEGER NOT NULL DEFAULT 0, ' +
  'progress_ratio REAL NOT NULL DEFAULT 0, ' +
  'reader_html TEXT NOT NULL DEFAULT \'\', ' +
  'content_html TEXT NOT NULL DEFAULT \'\', ' +
  'plain_text TEXT NOT NULL DEFAULT \'\', ' +
  'page_etag TEXT NOT NULL DEFAULT \'\', ' +
  'page_last_modified TEXT NOT NULL DEFAULT \'\', ' +
  // v7 跨源去重：归一化键 + 挂靠关系（空串 = 自己是主条）。
  'link_key TEXT NOT NULL DEFAULT \'\', ' +
  'title_key TEXT NOT NULL DEFAULT \'\', ' +
  'canonical_id TEXT NOT NULL DEFAULT \'\')';

/**
 * 标注表：一条 = 引文 + 可选备注 + 配色 + 定位信息。
 * 与 articles 分开存（一对多，且删文章时按 article_id 一起清），所以用独立 CREATE TABLE IF NOT EXISTS。
 */
const SQL_CREATE_HIGHLIGHTS: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_HIGHLIGHTS + ' (' +
  'id TEXT PRIMARY KEY, ' +
  'article_id TEXT NOT NULL, ' +
  'quote TEXT NOT NULL DEFAULT \'\', ' +
  'note TEXT NOT NULL DEFAULT \'\', ' +
  'color TEXT NOT NULL DEFAULT \'yellow\', ' +
  'created_at INTEGER NOT NULL DEFAULT 0, ' +
  'anchor_text TEXT NOT NULL DEFAULT \'\', ' +
  'anchor_ratio REAL NOT NULL DEFAULT 0)';

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
/** feed 自带的 HTML 正文（content:encoded / Atom content / JSON Feed content_html）。 */
const SQL_ADD_CONTENT_HTML: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN content_html TEXT NOT NULL DEFAULT \'\'';
/** 正文页协商缓存的两个校验器（条件请求用）。 */
const SQL_ADD_PAGE_ETAG: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN page_etag TEXT NOT NULL DEFAULT \'\'';
const SQL_ADD_PAGE_LAST_MODIFIED: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN page_last_modified TEXT NOT NULL DEFAULT \'\'';
/** Reader 正文的纯文本（提供搜索 / 复制 / 朗读复用）。 */
const SQL_ADD_PLAIN_TEXT: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN plain_text TEXT NOT NULL DEFAULT \'\'';
/** 稍后读（老库补列）。 */
const SQL_ADD_SAVED: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN is_saved INTEGER NOT NULL DEFAULT 0';
/** Reader 视图的结构化正文 HTML（提取 + 净化后）。 */
const SQL_ADD_READER: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN reader_html TEXT NOT NULL DEFAULT \'\'';
/** 规则隐藏标记（v6）；老库补列，默认 0 = 未隐藏。 */
const SQL_ADD_HIDDEN: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0';

/** 跨源去重 URL 归一化键（v7）；老库补列，默认空串 = 还没算过。 */
const SQL_ADD_LINK_KEY: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN link_key TEXT NOT NULL DEFAULT \'\'';
/** 跨源去重标题归一化键（v7）。 */
const SQL_ADD_TITLE_KEY: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN title_key TEXT NOT NULL DEFAULT \'\'';
/** 所属主条 id（v7）；空串 = 本条就是主条。 */
const SQL_ADD_CANONICAL: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN canonical_id TEXT NOT NULL DEFAULT \'\'';

/** 入库去重：单批最多处理 / 查询的键数（避免 IN 列表过长）。 */
const DEDUPE_KEY_BATCH: number = 200;

const SQL_INSERT: string =
  'INSERT OR IGNORE INTO ' + ArticleDbConstants.TABLE_ARTICLES +
  ' (id, feed_id, feed_title, title, link, summary, content, published_at, is_read, is_starred, fetched_at,' +
  ' image_url, author, content_html, link_key, title_key, canonical_id)' +
  ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

/** 备份导入：单事务最多处理的条数（2 万篇 ≈ 100 个短事务，避免长事务卡顿）。 */
const BACKUP_BATCH_SIZE: number = 200;

/** 备份导出：文章段只取元数据 + 阅读状态列（不含正文缓存 / fetched_at）。 */
const SQL_SELECT_BACKUP_ARTICLES: string =
  'SELECT id, feed_id, feed_title, title, link, summary, author, published_at, image_url,' +
  ' is_read, is_starred, is_saved, progress, progress_ratio, is_hidden,' +
  ' canonical_id, link_key, title_key FROM ' + ArticleDbConstants.TABLE_ARTICLES;

/** 备份导入：按 id 查已有文章的状态列（决定 INSERT 还是状态并集 UPDATE）。 */
const SQL_SELECT_BACKUP_ARTICLE_STATE: string =
  'SELECT id, is_read, is_starred, is_saved, is_hidden, progress, progress_ratio, canonical_id FROM ' +
  ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?';

/** 备份导入新文章：正文列留空（首次打开时重新提取），fetched_at 记导入时间。 */
const SQL_INSERT_BACKUP_ARTICLE: string =
  'INSERT INTO ' + ArticleDbConstants.TABLE_ARTICLES +
  ' (id, feed_id, feed_title, title, link, summary, content, published_at,' +
  ' is_read, is_starred, is_saved, is_hidden, fetched_at, image_url, author,' +
  ' progress, progress_ratio, link_key, title_key, canonical_id)' +
  ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

/** 备份导入已有文章：只并集状态列，不动标题 / 正文 / 来源等已有内容。 */
const SQL_UPDATE_BACKUP_ARTICLE_STATE: string =
  'UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
  ' SET is_read = ?, is_starred = ?, is_saved = ?, is_hidden = ?, progress = ?,' +
  ' progress_ratio = ?, canonical_id = ? WHERE id = ?';

/** 备份导出：标注段全字段。 */
const SQL_SELECT_BACKUP_HIGHLIGHTS: string =
  'SELECT id, article_id, quote, note, color, created_at, anchor_text, anchor_ratio FROM ' +
  ArticleDbConstants.TABLE_HIGHLIGHTS;

/** 备份导入标注：主键相同即忽略（幂等，不覆盖本地备注 / 配色）。 */
const SQL_INSERT_BACKUP_HIGHLIGHT: string =
  'INSERT OR IGNORE INTO ' + ArticleDbConstants.TABLE_HIGHLIGHTS +
  ' (id, article_id, quote, note, color, created_at, anchor_text, anchor_ratio)' +
  ' VALUES (?, ?, ?, ?, ?, ?, ?, ?)';

/** 备份导出：文章 ↔ 标签关联全表。 */
const SQL_SELECT_BACKUP_ARTICLE_TAGS: string =
  'SELECT article_id, tag_id FROM ' + ArticleDbConstants.TABLE_ARTICLE_TAGS;

/** 备份导入关联：联合主键相同即忽略（幂等）。 */
const SQL_INSERT_BACKUP_ARTICLE_TAG: string =
  'INSERT OR IGNORE INTO ' + ArticleDbConstants.TABLE_ARTICLE_TAGS +
  ' (article_id, tag_id) VALUES (?, ?)';

/** 列表：轻量列，按发布时间倒序；只取主条（重复项不进主表列表）。 */
const SQL_SELECT_LIST: string =
  'SELECT ' + LIST_COLUMNS + ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a' +
  ' WHERE a.canonical_id = \'\' ORDER BY a.published_at DESC';

/**
 * 摘要数据源：某时刻之后入库、仍未读、未隐藏、非重复项的轻量行。
 * 用 fetched_at（入库时间）而不是发布时间：摘要描述的是「今天新到的」。
 */
const SQL_SELECT_FETCHED_SINCE: string =
  'SELECT ' + LIST_COLUMNS + ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a' +
  ' WHERE a.fetched_at >= ? AND a.is_read = 0 AND a.is_hidden = 0 AND a.canonical_id = \'\'' +
  ' ORDER BY a.published_at DESC';

/** 正文：按 id 取。 */
const SQL_SELECT_BODY: string =
  'SELECT ' + BODY_COLUMNS + ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a WHERE a.id = ?';

/** 回收站表与主表同构 + deleted_at。 */
const SQL_CREATE_TRASH: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_ARTICLES_TRASH + ' (' +
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
  'is_saved INTEGER NOT NULL DEFAULT 0, ' +
  'is_hidden INTEGER NOT NULL DEFAULT 0, ' +
  'fetched_at INTEGER NOT NULL DEFAULT 0, ' +
  'image_url TEXT NOT NULL DEFAULT \'\', ' +
  'author TEXT NOT NULL DEFAULT \'\', ' +
  'progress INTEGER NOT NULL DEFAULT 0, ' +
  'progress_ratio REAL NOT NULL DEFAULT 0, ' +
  'reader_html TEXT NOT NULL DEFAULT \'\', ' +
  'content_html TEXT NOT NULL DEFAULT \'\', ' +
  'plain_text TEXT NOT NULL DEFAULT \'\', ' +
  'page_etag TEXT NOT NULL DEFAULT \'\', ' +
  'page_last_modified TEXT NOT NULL DEFAULT \'\', ' +
  'deleted_at INTEGER NOT NULL DEFAULT 0)';

/** v2 索引：按源取时间、按已读 / 收藏过滤、按文章取标注。 */
const SQL_INDEXES: string[] = [
  'CREATE INDEX IF NOT EXISTS idx_articles_feed_published ON ' +
    ArticleDbConstants.TABLE_ARTICLES + '(feed_id, published_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_articles_read ON ' +
    ArticleDbConstants.TABLE_ARTICLES + '(is_read)',
  'CREATE INDEX IF NOT EXISTS idx_articles_starred ON ' +
    ArticleDbConstants.TABLE_ARTICLES + '(is_starred)',
  'CREATE INDEX IF NOT EXISTS idx_highlights_article ON ' +
    ArticleDbConstants.TABLE_HIGHLIGHTS + '(article_id)'
];

/**
 * v4 标签表：name 是展示名（归一后），name_key 是去重键（小写 + 空白折叠），
 * 用 UNIQUE 约束兜住并发 / 重启后的重复创建。
 */
const SQL_CREATE_TAGS: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_TAGS + ' (' +
  'id TEXT PRIMARY KEY, ' +
  'name TEXT NOT NULL, ' +
  'name_key TEXT NOT NULL UNIQUE, ' +
  'created_at INTEGER NOT NULL DEFAULT 0)';

/**
 * v4 文章 ↔ 标签关联表：联合主键保证「同一标签重复添加不产生重复关联」。
 * 关联行随文章删除 / 回收站过期清除而清理，但移入 / 移出回收站时**保留**（恢复后标签仍在）。
 */
const SQL_CREATE_ARTICLE_TAGS: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_ARTICLE_TAGS + ' (' +
  'article_id TEXT NOT NULL, ' +
  'tag_id TEXT NOT NULL, ' +
  'PRIMARY KEY (article_id, tag_id))';

/** v4 智能文件夹表：只存检索语法原始串 + 手动排序位。 */
const SQL_CREATE_SMART_FOLDERS: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_SMART_FOLDERS + ' (' +
  'id TEXT PRIMARY KEY, ' +
  'name TEXT NOT NULL, ' +
  'query TEXT NOT NULL, ' +
  'sort_order INTEGER NOT NULL DEFAULT 0, ' +
  'created_at INTEGER NOT NULL DEFAULT 0, ' +
  'updated_at INTEGER NOT NULL DEFAULT 0)';

/** v4 索引：按标签反查文章（复合）、智能文件夹排序。 */
const SQL_INDEXES_V4: string[] = [
  'CREATE INDEX IF NOT EXISTS idx_article_tags_tag ON ' +
    ArticleDbConstants.TABLE_ARTICLE_TAGS + '(tag_id, article_id)',
  'CREATE INDEX IF NOT EXISTS idx_smart_folders_order ON ' +
    ArticleDbConstants.TABLE_SMART_FOLDERS + '(sort_order)'
];

/**
 * v5 远端账号表：只存地址 / 账号 / 状态，密码在 Asset Store。
 * failure_count / last_error 支持「连续失败次数与最近错误」可观测。
 */
const SQL_CREATE_REMOTE_ACCOUNTS: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_REMOTE_ACCOUNTS + ' (' +
  'id TEXT PRIMARY KEY, ' +
  'base_url TEXT NOT NULL DEFAULT \'\', ' +
  'username TEXT NOT NULL DEFAULT \'\', ' +
  'service_type TEXT NOT NULL DEFAULT \'greader\', ' +
  'enabled INTEGER NOT NULL DEFAULT 1, ' +
  'created_at INTEGER NOT NULL DEFAULT 0, ' +
  'updated_at INTEGER NOT NULL DEFAULT 0, ' +
  'last_sync_at INTEGER NOT NULL DEFAULT 0, ' +
  'failure_count INTEGER NOT NULL DEFAULT 0, ' +
  'last_error TEXT NOT NULL DEFAULT \'\')';

/** v5 同步状态表：key → value（last_sync_at / cursor_<feedId> / state_sync_at）。 */
const SQL_CREATE_SYNC_STATE: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_SYNC_STATE + ' (' +
  'key TEXT PRIMARY KEY, ' +
  'value TEXT NOT NULL DEFAULT \'\')';

/** v5 远端文章映射：远端 id → 本地文章 id（本地 id 由 buildArticleId 生成）。 */
const SQL_CREATE_REMOTE_MAP: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_REMOTE_ARTICLE_MAP + ' (' +
  'remote_id TEXT PRIMARY KEY, ' +
  'article_id TEXT NOT NULL, ' +
  'feed_id TEXT NOT NULL, ' +
  'updated_at INTEGER NOT NULL DEFAULT 0)';

/** v5 待同步队列：同一篇文章聚合为一行（已读 / 收藏各带目标值）。 */
const SQL_CREATE_SYNC_OUTBOX: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_SYNC_OUTBOX + ' (' +
  'article_id TEXT PRIMARY KEY, ' +
  'set_read INTEGER NOT NULL DEFAULT 0, ' +
  'read_value INTEGER NOT NULL DEFAULT 0, ' +
  'set_starred INTEGER NOT NULL DEFAULT 0, ' +
  'starred_value INTEGER NOT NULL DEFAULT 0, ' +
  'updated_at INTEGER NOT NULL DEFAULT 0, ' +
  'retries INTEGER NOT NULL DEFAULT 0, ' +
  'last_error TEXT NOT NULL DEFAULT \'\')';

/** v5 索引：按本地文章反查远端 id（回写状态 / 拉回状态都要用）。 */
const SQL_INDEXES_V5: string[] = [
  'CREATE INDEX IF NOT EXISTS idx_remote_map_article ON ' +
    ArticleDbConstants.TABLE_REMOTE_ARTICLE_MAP + '(article_id)'
];

/**
 * v6 规则表：关键词 / 来源 / 标签用 JSON 字符串数组存（脏数据读取端容错），
 * 字段 / 动作用逗号串（值域固定）。
 */
const SQL_CREATE_RULES: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_RULES + ' (' +
  'id TEXT PRIMARY KEY, ' +
  'name TEXT NOT NULL DEFAULT \'\', ' +
  'enabled INTEGER NOT NULL DEFAULT 1, ' +
  'priority INTEGER NOT NULL DEFAULT 0, ' +
  'keywords TEXT NOT NULL DEFAULT \'[]\', ' +
  'fields TEXT NOT NULL DEFAULT \'\', ' +
  'feed_ids TEXT NOT NULL DEFAULT \'[]\', ' +
  'actions TEXT NOT NULL DEFAULT \'\', ' +
  'tag_ids TEXT NOT NULL DEFAULT \'[]\', ' +
  'match_count INTEGER NOT NULL DEFAULT 0, ' +
  'last_hit_at INTEGER NOT NULL DEFAULT 0, ' +
  'created_at INTEGER NOT NULL DEFAULT 0, ' +
  'updated_at INTEGER NOT NULL DEFAULT 0)';

/** v6 索引：规则列表按优先级升序（同优先级按创建时间）。 */
const SQL_INDEXES_V6: string[] = [
  'CREATE INDEX IF NOT EXISTS idx_rules_priority ON ' +
    ArticleDbConstants.TABLE_RULES + '(priority, created_at)'
];

/**
 * v7 索引：按归一化键找已有文章（入库去重）、按主条取组内成员（列表来源数 / 组操作）。
 * link_key / title_key 上的空串行不参与匹配（查询只给非空键，索引里空串只会被跳过）。
 */
const SQL_INDEXES_V7: string[] = [
  'CREATE INDEX IF NOT EXISTS idx_articles_link_key ON ' +
    ArticleDbConstants.TABLE_ARTICLES + '(link_key)',
  'CREATE INDEX IF NOT EXISTS idx_articles_title_key ON ' +
    ArticleDbConstants.TABLE_ARTICLES + '(title_key, published_at)',
  'CREATE INDEX IF NOT EXISTS idx_articles_canonical ON ' +
    ArticleDbConstants.TABLE_ARTICLES + '(canonical_id)'
];

/** 远端映射写入（重复调用覆盖更新时间）。 */
const SQL_UPSERT_REMOTE_MAP: string =
  'INSERT OR REPLACE INTO ' + ArticleDbConstants.TABLE_REMOTE_ARTICLE_MAP +
  ' (remote_id, article_id, feed_id, updated_at) VALUES (?, ?, ?, ?)';

/** 正文列（loadBody 结果）。 */
export class ArticleBody {
  readonly content: string;
  readonly contentHtml: string;
  readonly readerHtml: string;
  readonly plainText: string;
  readonly pageEtag: string;
  readonly pageLastModified: string;

  constructor(content: string, contentHtml: string, readerHtml: string, plainText: string,
    pageEtag: string, pageLastModified: string) {
    this.content = content;
    this.contentHtml = contentHtml;
    this.readerHtml = readerHtml;
    this.plainText = plainText;
    this.pageEtag = pageEtag;
    this.pageLastModified = pageLastModified;
  }
}

/** 正文缓存占用快照。 */
export class CacheStats {
  readonly articles: number;
  readonly bytes: number;

  constructor(articles: number, bytes: number) {
    this.articles = articles;
    this.bytes = bytes;
  }
}

/**
 * 卡片展示用的轻量快照：未读数 + 最新几条（标题 + id）+ 最近一次抓取时间。
 * 带 id 是为了让卡片点击能深链到具体文章；带 fetched_at 是为了在卡片上显示「最近同步」。
 */
export class WidgetSnapshot {
  readonly unread: number;
  readonly titles: string[];
  readonly ids: string[];
  /** 最近一次抓取时间戳（0 表示本地还没有抓到过）。 */
  readonly lastFetchedAt: number;

  constructor(unread: number, titles: string[], ids: string[], lastFetchedAt: number) {
    this.unread = unread;
    this.titles = titles;
    this.ids = ids;
    this.lastFetchedAt = lastFetchedAt;
  }
}

/** 生成 n 个占位符（IN (?,?,…) 用）。 */
function placeholders(count: number): string {
  const parts: string[] = [];
  for (let i = 0; i < count; i += 1) {
    parts.push('?');
  }
  return parts.join(',');
}

/** 一次文章段合并的统计：新增 / 状态更新 / 因订阅缺失跳过。 */
export class BackupMergeCount {
  added: number;
  updated: number;
  skipped: number;

  constructor(added: number = 0, updated: number = 0, skipped: number = 0) {
    this.added = added;
    this.updated = updated;
    this.skipped = skipped;
  }
}

export class ArticleStore {
  private store: relationalStore.RdbStore | undefined = undefined;
  /** open() 是否已开始（用于区分「还没打开」与「正在打开」）。 */
  private openStarted: boolean = false;
  /** open() 是否已结束（成功或降级）。 */
  private readyResolved: boolean = false;
  private readyResolve: (() => void) | undefined = undefined;
  /** 库就绪信号：open() 结束后 resolve，供标签 / 智能文件夹等旁路 Store 等待，避免冷启动读到空库。 */
  private readyPromise: Promise<void> = new Promise<void>((resolve: () => void) => {
    this.readyResolve = resolve;
  });
  /** FTS 是否可用（建表失败 / 迁移降级时为 false，检索走 LIKE）。 */
  private ftsReady: boolean = false;
  /** 中文二元组索引是否可用（建表失败时为 false，中文检索降级为 LIKE）。 */
  private cjkReady: boolean = false;
  /** 设备中文分词能力（启动探针结论：文本 MATCH 是否真的可用）。 */
  private cjkFtsCapable: boolean = false;
  /** 最近一次统计的中文索引条数。 */
  private cjkIndexedCount: number = 0;
  /** 最近一次检索路径（fts / cjk / like；空串表示还没检索过）。 */
  private lastSearchPath: string = '';
  /** 最近一次检索耗时（毫秒）。 */
  private lastSearchMillis: number = 0;

  /** 打开（必要时建表 / 迁移）本地库。失败时降级为「无缓存」而不是崩溃。 */
  async open(context: common.Context): Promise<void> {
    this.openStarted = true;
    try {
      const config: relationalStore.StoreConfig = {
        name: ArticleDbConstants.DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      // 分词器只通过官方入口 StoreConfig.tokenizer 配置（建表语句里不再写 tokenize 子句）；
      // 设备不支持时退回默认分词：中文检索由中文二元组索引兜住，不再依赖分词器能力。
      let icu: boolean = false;
      try {
        icu = relationalStore.isTokenizerSupported(relationalStore.Tokenizer.ICU_TOKENIZER);
        if (icu) {
          config.tokenizer = relationalStore.Tokenizer.ICU_TOKENIZER;
        }
      } catch (err) {
        hilog.info(DOMAIN, TAG, 'tokenizer probe failed');
      }
      try {
        this.store = await relationalStore.getRdbStore(context, config);
      } catch (err) {
        if (!icu) {
          throw err as Error;
        }
        // 分词器配置与既有库不兼容：退回默认配置再开一次（检索降级，但数据可读）。
        const fallback: relationalStore.StoreConfig = {
          name: ArticleDbConstants.DB_NAME,
          securityLevel: relationalStore.SecurityLevel.S1
        };
        this.store = await relationalStore.getRdbStore(context, fallback);
        hilog.warn(DOMAIN, TAG, 'open with icu tokenizer failed, fell back to default');
      }
      this.store.executeSync(SQL_CREATE);
      this.addColumnIfNeeded(SQL_ADD_IMAGE);
      this.addColumnIfNeeded(SQL_ADD_AUTHOR);
      this.addColumnIfNeeded(SQL_ADD_PROGRESS);
      this.addColumnIfNeeded(SQL_ADD_PROGRESS_RATIO);
      this.addColumnIfNeeded(SQL_ADD_READER);
      this.addColumnIfNeeded(SQL_ADD_CONTENT_HTML);
      this.addColumnIfNeeded(SQL_ADD_PLAIN_TEXT);
      this.addColumnIfNeeded(SQL_ADD_PAGE_ETAG);
      this.addColumnIfNeeded(SQL_ADD_PAGE_LAST_MODIFIED);
      this.addColumnIfNeeded(SQL_ADD_SAVED);
      this.addColumnIfNeeded(SQL_ADD_HIDDEN);
      // v7 跨源去重三列：即使库已是最新版本也补一次（自愈：上次 ALTER 被打断）。
      this.addColumnIfNeeded(SQL_ADD_LINK_KEY);
      this.addColumnIfNeeded(SQL_ADD_TITLE_KEY);
      this.addColumnIfNeeded(SQL_ADD_CANONICAL);
      this.store.executeSync(SQL_CREATE_HIGHLIGHTS);
      // 标签 / 智能文件夹：即使库已是最新版本也执行一遍（自愈：上次建表失败 / 被打断）。
      this.createTagTables();
      // 远端账号 / 游标 / 映射 / 待同步队列同理：最新版本也自愈。
      this.createRemoteTables();
      // 规则表同理：最新版本也自愈（建表失败只让规则功能降级为空态）。
      this.createRuleTables();
      // v7 去重索引同理：最新版本也自愈（缺索引只是慢，功能不受影响）。
      this.createDedupeIndexes();
      // 结构迁移失败不删库：仅降级（无检索 / 无回收站），下次启动会重试。
      try {
        await this.migrate();
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.error(DOMAIN, TAG, 'migrate failed, degraded: %{public}d', error.code);
      }
      // 迁移完成后用真实中文样本探测一次 MATCH 能力（只有命中才算可用，结论进诊断状态）。
      this.cjkFtsCapable = await this.probeCjkFts();
      hilog.info(DOMAIN, TAG, 'CJKIDX probe result=%{public}s',
        this.cjkFtsCapable ? 'capable' : 'unavailable');
      await this.logIndexSchema();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'open failed: %{public}d', error.code);
      this.store = undefined;
      this.ftsReady = false;
      this.cjkReady = false;
    }
    this.markReady();
  }

  /**
   * 等待库打开结束（成功或降级）。
   * open() 尚未开始时立即返回，避免旁路 Store 在测试 / 无库场景下永久挂起。
   */
  whenReady(): Promise<void> {
    if (this.readyResolved || !this.openStarted) {
      return Promise.resolve();
    }
    return this.readyPromise;
  }

  private markReady(): void {
    if (this.readyResolved) {
      return;
    }
    this.readyResolved = true;
    const resolve: (() => void) | undefined = this.readyResolve;
    if (resolve !== undefined) {
      resolve();
    }
  }

  /** 版本化迁移：v1 = 初始表；v2 = 索引 + 回收站 + FTS；v3 = 中文检索索引；v4 = 标签 + 智能文件夹；
   *  v5 = 远端同步表；v6 = 规则表 + articles.is_hidden；
   *  v7 = 跨源去重：articles.link_key / title_key / canonical_id + 3 个索引。 */
  private async migrate(): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    let version: number = 0;
    try {
      version = store.version;
    } catch (err) {
      version = 0;
    }
    if (version >= ArticleDbConstants.SCHEMA_VERSION) {
      // 已是最新版本：仍确认两张索引真的可用（上次可能建表失败 / 重建被打断），必要时补建并在后台重建。
      // v4 / v5 / v6 的表已在 open() 里用 CREATE TABLE IF NOT EXISTS 自愈过，这里再补一次（幂等）。
      this.createRemoteTables();
      this.createRuleTables();
      this.createDedupeIndexes();
      const mainStale: boolean = await this.ensureMainIndex();
      const cjkStale: boolean = await this.ensureCjkIndex();
      if (mainStale) {
        this.backgroundRebuildMain();
      }
      if (cjkStale) {
        this.backgroundRebuildCjk();
      }
      return;
    }
    // 结构升级（v1 → v2 → v3 → v4，语句都可重复执行）。
    for (let i = 0; i < SQL_INDEXES.length; i += 1) {
      try {
        store.executeSync(SQL_INDEXES[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create index failed: %{public}d', error.code);
      }
    }
    store.executeSync(SQL_CREATE_TRASH);
    this.createTagTables();
    this.createRemoteTables();
    this.createRuleTables();
    this.createDedupeIndexes();
    const mainStale: boolean = await this.ensureMainIndex();
    const cjkStale: boolean = await this.ensureCjkIndex();
    try {
      store.version = ArticleDbConstants.SCHEMA_VERSION;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'set version failed: %{public}d', error.code);
    }
    // 首次升级：把已有文章灌进索引（后台分批，避免拖慢冷启动）。
    if (mainStale) {
      this.backgroundRebuildMain();
    }
    if (cjkStale) {
      this.backgroundRebuildCjk();
    }
  }

  /**
   * 建 v4 的三张表与索引（可重复执行）。
   *
   * 每条单独 try/catch：任何一条失败都只记日志、不影响其它语句，也不影响阅读 / 检索主链路 ——
   * 标签功能降级为「页面空态」，下次启动再自愈。
   */
  private createTagTables(): void {
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

  /**
   * 暴露共享连接：标签 / 智能文件夹 Store 复用它，避免同进程重复打开同名数据库。
   * undefined 表示库不可用（打开失败 / 正在降级），调用方应返回空态而不是抛错。
   */
  getStore(): relationalStore.RdbStore | undefined {
    return this.store;
  }

  /**
   * 建 v5 的四张表与索引（可重复执行）。
   * 每条单独 try/catch：任何一条失败只记日志，不影响阅读 / 检索主链路 ——
   * 远端同步功能降级，下次启动再自愈。
   */
  private createRemoteTables(): void {
    const statements: string[] = [
      SQL_CREATE_REMOTE_ACCOUNTS, SQL_CREATE_SYNC_STATE,
      SQL_CREATE_REMOTE_MAP, SQL_CREATE_SYNC_OUTBOX
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
  }

  /**
   * 建 v6 的规则表与索引（可重复执行）。
   * 每条单独 try/catch：失败只让规则功能降级为空态，不影响文章入库 / 阅读 / 检索。
   */
  private createRuleTables(): void {
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

  /**
   * 建 v7 的去重索引（可重复执行）。
   * 每条单独 try/catch：失败只让入库去重退化为全表扫描（变慢但结果一致），不影响入库本身。
   */
  private createDedupeIndexes(): void {
    for (let i = 0; i < SQL_INDEXES_V7.length; i += 1) {
      try {
        this.store?.executeSync(SQL_INDEXES_V7[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create dedupe index failed: %{public}d', error.code);
      }
    }
  }

  /** 后台重建主索引（升级 / 补建后回填，不阻塞启动）。 */
  private backgroundRebuildMain(): void {
    this.rebuildSearchIndex((): void => {
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'fts backfill failed: %{public}d', err.code);
    });
  }

  /** 后台重建中文索引（升级 / 补建 / 条数不一致时回填，不阻塞启动）。 */
  private backgroundRebuildCjk(): void {
    this.rebuildCjkIndex((): void => {
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'cjk backfill failed: %{public}d', err.code);
    });
  }

  /**
   * 确保主索引可用。返回 true 表示需要重建：索引条数与「需要索引的文章数」不一致
   * （跨源重复项不建索引，所以比的是主条数；建表晚于入库导致部分行缺失 / 重建被打断也会命中）。
   * 空库（文章 0 且索引 0）不需要重建。
   */
  private async ensureMainIndex(): Promise<boolean> {
    this.ftsReady = await this.detectFts();
    if (!this.ftsReady) {
      await this.createFts();
    }
    if (!this.ftsReady) {
      return false;
    }
    const indexed: number = await this.ftsCount();
    const total: number = await this.countIndexable();
    if (indexed === 0 && total === 0) {
      return false;
    }
    if (indexed !== total) {
      hilog.info(DOMAIN, TAG, 'main index mismatch indexed=%{public}d total=%{public}d',
        indexed, total);
      return true;
    }
    return false;
  }

  /**
   * 确保中文索引可用。返回 true 表示需要重建（表刚建好，或条数与主条数不一致 —— 重建被打断 / 有未同步的新数据）。
   * 建表失败时置 cjkReady = false 并返回 false：中文检索降级为 LIKE，功能仍可用。
   */
  private async ensureCjkIndex(): Promise<boolean> {
    this.cjkReady = await this.detectCjk();
    if (!this.cjkReady) {
      this.createCjk();
    }
    if (!this.cjkReady) {
      this.cjkIndexedCount = 0;
      hilog.warn(DOMAIN, TAG, 'CJKIDX cjk index degraded (create failed)');
      return false;
    }
    this.cjkIndexedCount = await this.cjkCount();
    const total: number = await this.countIndexable();
    if (this.cjkIndexedCount === 0 && total === 0) {
      return false;
    }
    if (this.cjkIndexedCount !== total) {
      hilog.info(DOMAIN, TAG, 'CJKIDX cjk index mismatch indexed=%{public}d total=%{public}d',
        this.cjkIndexedCount, total);
      return true;
    }
    return false;
  }

  /** 主索引建表：分词器只由 StoreConfig.tokenizer 提供（不再写 tokenize 子句）；失败则检索降级。 */
  private async createFts(): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    const columns: string = 'article_id UNINDEXED, title, summary, plain_text, author';
    try {
      store.executeSync('CREATE VIRTUAL TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_ARTICLES_FTS +
        ' USING fts5(' + columns + ')');
      this.ftsReady = true;
      hilog.info(DOMAIN, TAG, 'fts ready');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'create fts failed, degrade to like: %{public}d %{public}s',
        error.code, error.message);
      this.ftsReady = false;
    }
  }

  /**
   * 中文索引建表：显式 unicode61，保证写入的「字 / 二元组」token 原样保留、不被再次切碎。
   * 不使用其它分词参数；失败即降级（不重试别的写法）。
   */
  private createCjk(): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync('CREATE VIRTUAL TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK +
        ' USING fts5(article_id UNINDEXED, grams, tokenize=\'unicode61\')');
      this.cjkReady = true;
      hilog.info(DOMAIN, TAG, 'CJKIDX cjk index ready');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'CJKIDX create cjk fts failed: %{public}d %{public}s',
        error.code, error.message);
      this.cjkReady = false;
    }
  }

  /**
   * 中文分词能力探针：临时 FTS 表 + 中文样本 + 真实 MATCH。
   * 只有查询命中才算「中文分词可用」；失败静默（结论为不可用），探测表一定被清理。
   */
  private async probeCjkFts(): Promise<boolean> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return false;
    }
    const table: string = SearchConstants.PROBE_TABLE;
    try {
      store.executeSync('DROP TABLE IF EXISTS ' + table);
      store.executeSync('CREATE VIRTUAL TABLE ' + table + ' USING fts5(body)');
      store.executeSync('INSERT INTO ' + table + ' (body) VALUES (?)', [SearchConstants.PROBE_SAMPLE]);
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM ' + table + ' WHERE body MATCH ?',
        [escapeFtsToken(SearchConstants.PROBE_TERM)]);
      try {
        const hit: number = rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
        return hit > 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'CJKIDX probe failed: %{public}d %{public}s', error.code, error.message);
      return false;
    } finally {
      this.dropProbeTable();
    }
  }

  /** 清理探针临时表（失败忽略：表可能根本没建成）。 */
  private dropProbeTable(): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync('DROP TABLE IF EXISTS ' + SearchConstants.PROBE_TABLE);
    } catch (err) {
      hilog.info(DOMAIN, TAG, 'CJKIDX probe table cleanup skipped');
    }
  }

  /** 探测 FTS 是否可用（表存在且能查询）。 */
  private async detectFts(): Promise<boolean> {
    return await this.tableQueryable(ArticleDbConstants.TABLE_ARTICLES_FTS);
  }

  /**
   * 启动时把两张索引虚表的真实 DDL 打进日志（诊断用）：
   * 建表失败 / 旧版本残留 / 分词参数不符时，只有 sqlite_master 里的原文能说明问题。
   */
  private async logIndexSchema(): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    const tables: string[] = [ArticleDbConstants.TABLE_ARTICLES_FTS, ArticleDbConstants.TABLE_ARTICLES_FTS_CJK];
    for (let i = 0; i < tables.length; i += 1) {
      try {
        const rs: relationalStore.ResultSet = await store.querySql(
          'SELECT sql FROM sqlite_master WHERE type = ? AND name = ?', ['table', tables[i]]);
        try {
          const ddl: string = rs.goToNextRow() ? rs.getString(rs.getColumnIndex('sql')) : '';
          hilog.info(DOMAIN, TAG, 'CJKIDX schema %{public}s: %{public}s',
            tables[i], ddl.length > 0 ? ddl : '(missing)');
        } finally {
          rs.close();
        }
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'CJKIDX schema dump failed: %{public}d %{public}s',
          error.code, error.message);
      }
    }
  }

  /** 探测中文索引表是否可用。 */
  private async detectCjk(): Promise<boolean> {
    return await this.tableQueryable(ArticleDbConstants.TABLE_ARTICLES_FTS_CJK);
  }

  private async tableQueryable(table: string): Promise<boolean> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return false;
    }
    // 先以 sqlite_master 为准确认表真的存在：仅靠 SELECT 是否抛错判断会误判（缺表时可能返回空结果集）。
    if (!(await this.tableExists(table))) {
      return false;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql('SELECT COUNT(*) AS c FROM ' + table);
      try {
        return rs.goToNextRow();
      } finally {
        rs.close();
      }
    } catch (err) {
      return false;
    }
  }

  /** 表是否存在于当前库（sqlite_master 为准）。 */
  private async tableExists(table: string): Promise<boolean> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return false;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM sqlite_master WHERE type = ? AND name = ?', ['table', table]);
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) > 0 : false;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'table exists check failed: %{public}d %{public}s',
        error.code, error.message);
      return false;
    }
  }

  /** 检索索引是否可用。 */
  isFtsReady(): boolean {
    return this.ftsReady;
  }

  /** 中文索引是否可用（false = 中文检索降级为 LIKE）。 */
  isCjkIndexReady(): boolean {
    return this.cjkReady;
  }

  /** 诊断快照：索引就绪状态 / 条数 / 最近一次检索路径与耗时。 */
  async diagnostics(): Promise<SearchDiagnostics> {
    const mainIndexed: number = await this.ftsCount();
    this.cjkIndexedCount = await this.cjkCount();
    hilog.info(DOMAIN, TAG, 'CJKIDX diagnostics ready=%{public}d/%{public}d main=%{public}d cjk=%{public}d',
      this.ftsReady ? 1 : 0, this.cjkReady ? 1 : 0, mainIndexed, this.cjkIndexedCount);
    return new SearchDiagnostics(this.ftsReady, this.cjkReady, this.cjkFtsCapable,
      mainIndexed, this.cjkIndexedCount, this.lastSearchPath, this.lastSearchMillis);
  }

  /** FTS 行数（诊断 / 判断是否需要首次回填）。 */
  private async ftsCount(): Promise<number> {
    return await this.tableCount(ArticleDbConstants.TABLE_ARTICLES_FTS, this.ftsReady);
  }

  /** 中文索引行数。 */
  private async cjkCount(): Promise<number> {
    return await this.tableCount(ArticleDbConstants.TABLE_ARTICLES_FTS_CJK, this.cjkReady);
  }

  /**
   * FTS5 虚表行数。
   * 本 RDB 封装下对 FTS5 虚表直接 COUNT(*) 会返回 0（而 MATCH 查询正常），
   * 故优先统计 FTS5 的文档影子表 `<table>_docsize`（每个文档一行）；
   * 影子表不可用（未建成 / 旧版本）时退回虚表 COUNT(*)；两者都失败静默返回 0。
   */
  private async tableCount(table: string, ready: boolean): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || !ready) {
      return 0;
    }
    const shadow: string = table + '_docsize';
    try {
      const rs: relationalStore.ResultSet =
        await store.querySql('SELECT COUNT(*) AS c FROM ' + shadow);
      try {
        if (rs.goToNextRow()) {
          return rs.getLong(rs.getColumnIndex('c'));
        }
        hilog.warn(DOMAIN, TAG, 'count %{public}s returned no row, fallback to fts count', shadow);
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'count %{public}s failed, fallback to fts count: %{public}d %{public}s',
        shadow, error.code, error.message);
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql('SELECT COUNT(*) AS c FROM ' + table);
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'count %{public}s failed, report 0: %{public}d %{public}s',
        table, error.code, error.message);
      return 0;
    }
  }

  /**
   * 需要进入检索索引的条数（= 主条数）：
   * 跨源重复项入库时不写索引，若仍拿全表条数比较，每次启动都会误判「索引缺行」并全量重建。
   */
  private async countIndexable(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE canonical_id = \'\'');
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'countIndexable failed: %{public}d', error.code);
      return 0;
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
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'loadForList failed: %{public}d', error.code);
    }
    return result;
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
   * 轻量列表行 → Article（loadForList / loadHidden 共用，字段映射保持一致）。
   * 正文列不在列表查询里，正文由 loadBody 按需加载。
   */
  private articleFromListRow(rs: relationalStore.ResultSet): Article {
    const article: Article = new Article(
      rs.getString(rs.getColumnIndex('id')),
      rs.getString(rs.getColumnIndex('feed_id')),
      rs.getString(rs.getColumnIndex('feed_title')),
      rs.getString(rs.getColumnIndex('title')),
      rs.getString(rs.getColumnIndex('link')),
      rs.getString(rs.getColumnIndex('summary')),
      '',
      rs.getLong(rs.getColumnIndex('published_at'))
    );
    article.imageUrl = rs.getString(rs.getColumnIndex('image_url'));
    article.author = rs.getString(rs.getColumnIndex('author'));
    article.read = rs.getLong(rs.getColumnIndex('is_read')) === 1;
    article.starred = rs.getLong(rs.getColumnIndex('is_starred')) === 1;
    article.saved = rs.getLong(rs.getColumnIndex('is_saved')) === 1;
    article.hidden = rs.getLong(rs.getColumnIndex('is_hidden')) === 1;
    // 用 getDouble 读：老数据里可能残留小数（列是 INTEGER，但 SQLite 动态类型允许 REAL）。
    article.progress = rs.getDouble(rs.getColumnIndex('progress'));
    article.progressRatio = rs.getDouble(rs.getColumnIndex('progress_ratio'));
    article.readerState = rs.getLong(rs.getColumnIndex('has_reader')) === 1
      ? ReaderState.READY
      : ReaderState.NONE;
    // 跨源去重：canonical_id 空串 = 主条；duplicateCount 是「含自己的组内来源数」。
    article.canonicalId = rs.getString(rs.getColumnIndex('canonical_id'));
    article.duplicateCount = 1 + rs.getLong(rs.getColumnIndex('dup_count'));
    return article;
  }

  /** 兼容旧调用：列表读取（轻量列）。 */
  async loadRecent(): Promise<Article[]> {
    return await this.loadForList();
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
            item.linkKey, item.titleKey, canonical
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

  /**
   * 全文检索路由（所有过滤条件与分页都在 SQL 层完成）：
   *   含 CJK      → 中文二元组索引（articles_fts_cjk）+ 候选复核；
   *   纯英文      → 主 FTS 索引（articles_fts）；
   *   索引不可用 / 查询异常 → 全表 LIKE 降级（功能仍可用）。
   * 每次检索都记录路径与耗时（诊断 + CJKIDX 日志）。
   */
  async search(query: SearchQuery, offset: number, limit: number): Promise<SearchPage> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || limit <= 0) {
      return SearchPage.empty();
    }
    // 空查询保护：没有任何关键词与过滤条件时直接返回空页，不触发任何扫描。
    if (isBlankQuery(query)) {
      return SearchPage.empty();
    }
    const started: number = Date.now();
    if (hasCjk(query)) {
      if (this.cjkReady) {
        try {
          const plan: CjkQueryPlan = compile(query);
          if (plan.used) {
            const page: SearchPage = await this.searchCjk(store, query, plan, offset, limit);
            return this.finishSearch(page, SearchConstants.PATH_CJK, started);
          }
        } catch (err) {
          const error: BusinessError = err as BusinessError;
          hilog.warn(DOMAIN, TAG, 'CJKIDX cjk search failed, fallback like: %{public}d', error.code);
        }
      } else {
        hilog.info(DOMAIN, TAG, 'CJKIDX cjk index unavailable, like fallback');
      }
      const fallback: SearchPage = await this.searchLike(store, query, offset, limit);
      return this.finishSearch(fallback, SearchConstants.PATH_LIKE, started);
    }
    if (this.ftsReady) {
      try {
        const expression: string = this.ftsExpression(query);
        if (expression.length > 0) {
          const page: SearchPage = await this.searchFts(store, query, expression, offset, limit);
          return this.finishSearch(page, SearchConstants.PATH_FTS, started);
        }
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'fts search failed, falling back to like: %{public}d', error.code);
      }
    }
    const like: SearchPage = await this.searchLike(store, query, offset, limit);
    return this.finishSearch(like, SearchConstants.PATH_LIKE, started);
  }

  /** 记录最近一次检索路径与耗时（诊断状态 + 日志）。 */
  private finishSearch(page: SearchPage, path: string, started: number): SearchPage {
    const millis: number = Math.max(0, Date.now() - started);
    this.lastSearchPath = path;
    this.lastSearchMillis = millis;
    hilog.info(DOMAIN, TAG, 'CJKIDX search path=%{public}s ms=%{public}d total=%{public}d',
      path, millis, page.total);
    return page;
  }

  /** 拼 FTS5 查询串：短语整体匹配，普通词按 AND；每个词都做转义。 */
  private ftsExpression(query: SearchQuery): string {
    if (query.phrase.length > 0) {
      return escapeFtsToken(query.phrase);
    }
    const parts: string[] = [];
    for (let i = 0; i < query.terms.length; i += 1) {
      const token: string = escapeFtsToken(query.terms[i]);
      if (token.length > 0) {
        parts.push(token);
      }
    }
    return parts.join(' AND ');
  }

  /**
   * 状态 / 来源 / 时间过滤的 SQL 片段（不含关键词）。
   * 开头的 canonical_id 条件让检索（计数与取页）只命中主条：重复项不进搜索结果。
   */
  private filterClause(query: SearchQuery, args: Array<relationalStore.ValueType>): string {
    let clause: string = ' AND a.canonical_id = \'\'';
    if (query.state === SearchState.UNREAD) {
      clause += ' AND a.is_read = 0';
    } else if (query.state === SearchState.READ) {
      clause += ' AND a.is_read = 1';
    } else if (query.state === SearchState.STARRED) {
      clause += ' AND a.is_starred = 1';
    } else if (query.state === SearchState.SAVED) {
      clause += ' AND a.is_saved = 1';
    }
    const from: string = query.from.trim();
    if (from.length > 0) {
      clause += ' AND (a.feed_title LIKE ? OR a.feed_id LIKE ?)';
      args.push('%' + from + '%');
      args.push('%' + from + '%');
    }
    if (query.after > 0) {
      clause += ' AND a.published_at >= ?';
      args.push(query.after);
    }
    if (query.before > 0) {
      clause += ' AND a.published_at < ?';
      args.push(query.before);
    }
    return clause;
  }

  /** 片段提取用的关键词（第一个词 / 短语）。 */
  private snippetTerm(query: SearchQuery): string {
    if (query.phrase.length > 0) {
      return query.phrase;
    }
    return query.terms.length > 0 ? query.terms[0] : '';
  }

  /** 命中片段列：在 plain_text 里找关键词并裁切，找不到退回摘要。 */
  private snippetColumn(): string {
    return ', CASE' +
      ' WHEN instr(lower(a.plain_text), lower(?)) > 0 THEN substr(a.plain_text,' +
      ' MAX(1, instr(lower(a.plain_text), lower(?)) - 40), ' + SearchConstants.SNIPPET_MAX_CHARS + ')' +
      ' WHEN length(a.summary) > 0 THEN substr(a.summary, 1, ' + SearchConstants.SNIPPET_MAX_CHARS + ')' +
      ' ELSE substr(a.plain_text, 1, ' + SearchConstants.SNIPPET_MAX_CHARS + ') END AS snippet';
  }

  private async searchFts(store: relationalStore.RdbStore, query: SearchQuery,
    expression: string, offset: number, limit: number): Promise<SearchPage> {
    const countArgs: Array<relationalStore.ValueType> = [expression];
    // FTS5 的 MATCH 左操作数必须是表名，不能是别名，故 FTS 表不加别名。
    const countSql: string = 'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS +
      ' JOIN ' + ArticleDbConstants.TABLE_ARTICLES + ' a ON a.id = ' +
      ArticleDbConstants.TABLE_ARTICLES_FTS + '.article_id' +
      ' WHERE ' + ArticleDbConstants.TABLE_ARTICLES_FTS + ' MATCH ?' + this.filterClause(query, countArgs);
    const total: number = await this.queryCount(store, countSql, countArgs, true);

    const term: string = this.snippetTerm(query);
    const args: Array<relationalStore.ValueType> = [term, term, expression];
    const sql: string = 'SELECT a.id, a.title, a.feed_title, a.published_at, a.is_read, a.is_starred, a.is_saved' +
      this.snippetColumn() +
      ' FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS +
      ' JOIN ' + ArticleDbConstants.TABLE_ARTICLES + ' a ON a.id = ' +
      ArticleDbConstants.TABLE_ARTICLES_FTS + '.article_id' +
      ' WHERE ' + ArticleDbConstants.TABLE_ARTICLES_FTS + ' MATCH ?' + this.filterClause(query, args) +
      ' ORDER BY a.published_at DESC LIMIT ? OFFSET ?';
    args.push(limit);
    args.push(offset);
    const hits: SearchHit[] = await this.queryHits(store, sql, args, true);
    return new SearchPage(hits, total, offset + hits.length < total);
  }

  /**
   * 中文索引路径：MATCH 二元组表达式 + 复核条件。
   * 计数用 COUNT(DISTINCT a.id)、取页用 SELECT DISTINCT：索引里同篇文章理论上只有一行，
   * 但重建中断等异常可能留下重复行，去重后 total 与分页才能保持一致。
   */
  private async searchCjk(store: relationalStore.RdbStore, query: SearchQuery,
    plan: CjkQueryPlan, offset: number, limit: number): Promise<SearchPage> {
    const countArgs: Array<relationalStore.ValueType> = [plan.expression];
    const countFilter: string = this.filterClause(query, countArgs);
    const countPost: string = postFilterSql(plan, 'a', countArgs);
    // FTS5 的 MATCH 左操作数必须是表名，不能是别名，故中文索引表不加别名。
    const countSql: string = 'SELECT COUNT(DISTINCT a.id) AS c FROM ' +
      ArticleDbConstants.TABLE_ARTICLES_FTS_CJK + ' JOIN ' + ArticleDbConstants.TABLE_ARTICLES +
      ' a ON a.id = ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK + '.article_id' +
      ' WHERE ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK + ' MATCH ?' + countFilter + countPost;
    const total: number = await this.queryCount(store, countSql, countArgs, true);

    const term: string = this.snippetTerm(query);
    const args: Array<relationalStore.ValueType> = [term, term, plan.expression];
    const filter: string = this.filterClause(query, args);
    const post: string = postFilterSql(plan, 'a', args);
    const sql: string = 'SELECT DISTINCT a.id, a.title, a.feed_title, a.published_at,' +
      ' a.is_read, a.is_starred, a.is_saved' + this.snippetColumn() +
      ' FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK +
      ' JOIN ' + ArticleDbConstants.TABLE_ARTICLES + ' a ON a.id = ' +
      ArticleDbConstants.TABLE_ARTICLES_FTS_CJK + '.article_id' +
      ' WHERE ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK + ' MATCH ?' + filter + post +
      ' ORDER BY a.published_at DESC LIMIT ? OFFSET ?';
    args.push(limit);
    args.push(offset);
    const hits: SearchHit[] = await this.queryHits(store, sql, args, true);
    return new SearchPage(hits, total, offset + hits.length < total);
  }

  /** LIKE 降级：分页子串匹配（不依赖分词器，中文一定能命中）。 */
  private async searchLike(store: relationalStore.RdbStore, query: SearchQuery,
    offset: number, limit: number): Promise<SearchPage> {
    const keyword: string = (query.phrase.length > 0 ? query.phrase : query.terms.join(' ')).trim();
    const hasKeyword: boolean = keyword.length > 0;
    const like: string = '%' + keyword + '%';
    const where: string = hasKeyword
      ? ' WHERE (a.title LIKE ? OR a.summary LIKE ? OR a.plain_text LIKE ? OR a.author LIKE ?)'
      : ' WHERE 1 = 1';
    const countArgs: Array<relationalStore.ValueType> = hasKeyword ? [like, like, like, like] : [];
    const countSql: string = 'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a' +
      where + this.filterClause(query, countArgs);
    const total: number = await this.queryCount(store, countSql, countArgs);

    // 占位符顺序：先 SELECT 片段里的两个关键词，再 WHERE 的四个 LIKE（无关键词时没有 LIKE）。
    const args: Array<relationalStore.ValueType> = [keyword, keyword];
    if (hasKeyword) {
      args.push(like);
      args.push(like);
      args.push(like);
      args.push(like);
    }
    const sql: string = 'SELECT a.id, a.title, a.feed_title, a.published_at, a.is_read, a.is_starred, a.is_saved' +
      this.snippetColumn() +
      ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a' + where + this.filterClause(query, args) +
      ' ORDER BY a.published_at DESC LIMIT ? OFFSET ?';
    args.push(limit);
    args.push(offset);
    const hits: SearchHit[] = await this.queryHits(store, sql, args);
    return new SearchPage(hits, total, offset + hits.length < total);
  }

  /**
   * 计数查询。strict = true 时 SQL 出错直接向上抛（检索路径用，交给 search() 降级 LIKE 并打日志）；
   * 默认 false 保持其它调用点「出错返回 0」的旧行为。
   */
  private async queryCount(store: relationalStore.RdbStore, sql: string,
    args: Array<relationalStore.ValueType>, strict: boolean = false): Promise<number> {
    try {
      const rs: relationalStore.ResultSet = await store.querySql(sql, args);
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'count query failed: %{public}d', error.code);
      if (strict) {
        throw error as Error;
      }
      return 0;
    }
  }

  /**
   * 取页查询。strict = true 时 SQL 出错直接向上抛；默认 false 保持旧行为（出错返回已取到的部分）。
   */
  private async queryHits(store: relationalStore.RdbStore, sql: string,
    args: Array<relationalStore.ValueType>, strict: boolean = false): Promise<SearchHit[]> {
    const hits: SearchHit[] = [];
    try {
      const rs: relationalStore.ResultSet = await store.querySql(sql, args);
      try {
        while (rs.goToNextRow()) {
          hits.push(new SearchHit(
            rs.getString(rs.getColumnIndex('id')),
            rs.getString(rs.getColumnIndex('title')),
            rs.getString(rs.getColumnIndex('snippet')),
            rs.getString(rs.getColumnIndex('feed_title')),
            rs.getLong(rs.getColumnIndex('published_at')),
            rs.getLong(rs.getColumnIndex('is_read')) === 1,
            rs.getLong(rs.getColumnIndex('is_starred')) === 1,
            rs.getLong(rs.getColumnIndex('is_saved')) === 1));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'search query failed: %{public}d', error.code);
      if (strict) {
        throw error as Error;
      }
    }
    return hits;
  }

  /**
   * 全量重建检索索引：分批（每批 REBUILD_BATCH 条）写入并回调进度，不阻塞阅读（异步分批）。
   */
  async rebuildSearchIndex(onProgress: (done: number, total: number) => void): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    if (!this.ftsReady) {
      await this.createFts();
      if (!this.ftsReady) {
        onProgress(0, 0);
        return;
      }
    }
    try {
      store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS);
      const total: number = await this.countIndexable();
      let done: number = 0;
      onProgress(0, total);
      let offset: number = 0;
      while (offset < total) {
        const rs: relationalStore.ResultSet = await store.querySql(
          'SELECT id, title, summary, plain_text, author FROM ' + ArticleDbConstants.TABLE_ARTICLES +
          ' WHERE canonical_id = \'\' ORDER BY published_at DESC LIMIT ? OFFSET ?',
          [SearchConstants.REBUILD_BATCH, offset]);
        const rows: Array<Array<string>> = [];
        try {
          while (rs.goToNextRow()) {
            rows.push([
              rs.getString(rs.getColumnIndex('id')),
              rs.getString(rs.getColumnIndex('title')),
              rs.getString(rs.getColumnIndex('summary')),
              rs.getString(rs.getColumnIndex('plain_text')),
              rs.getString(rs.getColumnIndex('author'))
            ]);
          }
        } finally {
          rs.close();
        }
        if (rows.length === 0) {
          break;
        }
        store.beginTransaction();
        try {
          for (let i = 0; i < rows.length; i += 1) {
            this.ftsInsert(rows[i][0], rows[i][1], rows[i][2], rows[i][3], rows[i][4]);
          }
          store.commit();
        } catch (inner) {
          store.rollBack();
          throw inner as Error;
        }
        done += rows.length;
        offset += rows.length;
        onProgress(done, total);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'rebuild index failed: %{public}d %{public}s',
        error.code, error.message);
    }
  }

  /**
   * 全量重建中文索引：分批（每批 REBUILD_BATCH 条）+ 每批一个事务，回调进度；不阻塞阅读。
   * 中断（应用被杀）后下次启动会重新构建：先清空再写，保证不产生重复行 / 半截数据被当成完整索引。
   * 失败时保留已写入的部分并刷新条数（诊断可见），检索仍可用（未命中走 LIKE 复核兜底）。
   */
  async rebuildCjkIndex(onProgress: (done: number, total: number) => void): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    if (!this.cjkReady) {
      this.createCjk();
      if (!this.cjkReady) {
        onProgress(0, 0);
        return;
      }
    }
    try {
      const existing: number = await this.cjkCount();
      if (existing > 0) {
        store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK);
      }
      const total: number = await this.countIndexable();
      let done: number = 0;
      onProgress(0, total);
      let offset: number = 0;
      while (offset < total) {
        const rs: relationalStore.ResultSet = await store.querySql(
          'SELECT id, title, summary, plain_text, content FROM ' + ArticleDbConstants.TABLE_ARTICLES +
          ' WHERE canonical_id = \'\' ORDER BY published_at DESC LIMIT ? OFFSET ?',
          [SearchConstants.REBUILD_BATCH, offset]);
        const rows: Array<Array<string>> = [];
        try {
          while (rs.goToNextRow()) {
            rows.push([
              rs.getString(rs.getColumnIndex('id')),
              rs.getString(rs.getColumnIndex('title')),
              rs.getString(rs.getColumnIndex('summary')),
              rs.getString(rs.getColumnIndex('plain_text')),
              rs.getString(rs.getColumnIndex('content'))
            ]);
          }
        } finally {
          rs.close();
        }
        if (rows.length === 0) {
          break;
        }
        store.beginTransaction();
        try {
          for (let i = 0; i < rows.length; i += 1) {
            this.cjkInsert(rows[i][0], rows[i][1], rows[i][2], this.plainOf(rows[i][3], rows[i][4]));
          }
          store.commit();
        } catch (inner) {
          store.rollBack();
          throw inner as Error;
        }
        done += rows.length;
        offset += rows.length;
        onProgress(done, total);
      }
      this.cjkIndexedCount = await this.cjkCount();
      hilog.info(DOMAIN, TAG, 'CJKIDX cjk rebuilt rows=%{public}d', this.cjkIndexedCount);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      // 重建失败保留旧状态（已写入的部分仍可用），只记日志 + 刷新条数。
      this.cjkIndexedCount = await this.cjkCount();
      hilog.error(DOMAIN, TAG, 'CJKIDX rebuild cjk index failed: %{public}d %{public}s',
        error.code, error.message);
    }
  }

  /** 正文纯文本：优先 plain_text（Reader 已提取），否则从 content 粗略转一次。 */
  private plainOf(plainText: string, content: string): string {
    return plainText.length > 0 ? plainText : toPlainText(content);
  }

  /** 一篇文档的 CJK token 流：标题 + 摘要 + 正文纯文本，受单篇字符上限约束。 */
  private gramsOf(title: string, summary: string, plainText: string): string {
    const text: string = title + ' ' + summary + ' ' + plainText;
    return grams(text, SearchConstants.CJK_GRAMS_MAX_CHARS);
  }

  private ftsInsert(articleId: string, title: string, summary: string,
    plainText: string, author: string): void {
    try {
      const store: relationalStore.RdbStore | undefined = this.store;
      if (store === undefined || !this.ftsReady) {
        return;
      }
      store.executeSync('INSERT INTO ' + ArticleDbConstants.TABLE_ARTICLES_FTS +
        ' (article_id, title, summary, plain_text, author) VALUES (?, ?, ?, ?, ?)',
        [articleId, title, summary, plainText, author]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'fts insert failed: %{public}d %{public}s', error.code, error.message);
    }
  }

  /** 有则更新、无则插入（setReaderHtml / 回填用）。 */
  private ftsUpsert(articleId: string, title: string, summary: string,
    plainText: string, author: string): void {
    try {
      const store: relationalStore.RdbStore | undefined = this.store;
      if (store === undefined || !this.ftsReady) {
        return;
      }
      store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES_FTS +
        ' SET title = ?, summary = ?, plain_text = ?, author = ? WHERE article_id = ?',
        [title, summary, plainText, author, articleId]);
      if (this.lastChanges() === 0) {
        this.ftsInsert(articleId, title, summary, plainText, author);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'fts upsert failed: %{public}d', error.code);
    }
  }

  private deleteFtsRows(ids: string[]): void {
    if (!this.ftsReady || ids.length === 0) {
      return;
    }
    for (let i = 0; i < ids.length; i += 1) {
      this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS + ' WHERE article_id = ?', [ids[i]]);
    }
  }

  /**
   * 写一行中文索引（失败只记日志：索引是增强能力，不能影响入库 / 阅读）。
   * 纯英文文章也写一行（grams 为空）：这样索引行数恒等于文章数，
   * 「条数不一致 = 重建被打断」的判断才成立，否则每次启动都会误判为需要重建。
   */
  private cjkInsert(articleId: string, title: string, summary: string, plainText: string): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || !this.cjkReady) {
      return;
    }
    try {
      const tokenStream: string = this.gramsOf(title, summary, plainText);
      store.executeSync('INSERT INTO ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK +
        ' (article_id, grams) VALUES (?, ?)', [articleId, tokenStream]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'CJKIDX cjk insert failed: %{public}d %{public}s',
        error.code, error.message);
    }
  }

  /** 有则更新、无则插入（setReaderHtml / 恢复 / 回填用）。 */
  private cjkUpsert(articleId: string, title: string, summary: string, plainText: string): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || !this.cjkReady) {
      return;
    }
    try {
      const tokenStream: string = this.gramsOf(title, summary, plainText);
      store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK +
        ' SET grams = ? WHERE article_id = ?', [tokenStream, articleId]);
      if (this.lastChanges() === 0) {
        store.executeSync('INSERT INTO ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK +
          ' (article_id, grams) VALUES (?, ?)', [articleId, tokenStream]);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'CJKIDX cjk upsert failed: %{public}d %{public}s',
        error.code, error.message);
    }
  }

  private cjkDeleteRows(ids: string[]): void {
    if (!this.cjkReady || ids.length === 0) {
      return;
    }
    for (let i = 0; i < ids.length; i += 1) {
      this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK + ' WHERE article_id = ?',
        [ids[i]]);
    }
  }

  /** 上一条语句影响的行数（同连接内 changes()）。 */
  private lastChanges(): number {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync('SELECT changes() AS c');
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      return 0;
    }
  }

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
    const store: relationalStore.RdbStore | undefined = this.store;
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
    const store: relationalStore.RdbStore | undefined = this.store;
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
    const store: relationalStore.RdbStore | undefined = this.store;
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

  /**
   * 清理正文缓存：清空未收藏文章的 reader_html / content_html / plain_text / 阅读进度，
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
        ' SET reader_html = \'\', content_html = \'\', plain_text = \'\', progress = 0, progress_ratio = 0' +
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

  markAllRead(): void {
    this.exec('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES + ' SET is_read = 1 WHERE is_read = 0', []);
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
            rs.getString(rs.getColumnIndex('id')),
            rs.getString(rs.getColumnIndex('feed_id')),
            rs.getString(rs.getColumnIndex('feed_title')),
            rs.getString(rs.getColumnIndex('title')),
            rs.getString(rs.getColumnIndex('link')),
            rs.getString(rs.getColumnIndex('summary')),
            rs.getString(rs.getColumnIndex('author')),
            rs.getLong(rs.getColumnIndex('published_at')),
            rs.getString(rs.getColumnIndex('image_url')),
            rs.getLong(rs.getColumnIndex('is_read')) === 1,
            rs.getLong(rs.getColumnIndex('is_starred')) === 1,
            rs.getLong(rs.getColumnIndex('is_saved')) === 1,
            rs.getLong(rs.getColumnIndex('is_hidden')) === 1,
            rs.getDouble(rs.getColumnIndex('progress')),
            rs.getDouble(rs.getColumnIndex('progress_ratio')),
            rs.getString(rs.getColumnIndex('canonical_id')),
            rs.getString(rs.getColumnIndex('link_key')),
            rs.getString(rs.getColumnIndex('title_key'))));
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
        rs.getLong(rs.getColumnIndex('is_read')) === 1,
        rs.getLong(rs.getColumnIndex('is_starred')) === 1,
        rs.getLong(rs.getColumnIndex('is_saved')) === 1,
        rs.getLong(rs.getColumnIndex('is_hidden')) === 1,
        rs.getDouble(rs.getColumnIndex('progress')),
        rs.getDouble(rs.getColumnIndex('progress_ratio')),
        rs.getString(rs.getColumnIndex('canonical_id')));
    } finally {
      rs.close();
    }
  }

  /** 导出标注段（全表）。 */
  async allHighlightsForBackup(): Promise<BackupHighlight[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
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
    const store: relationalStore.RdbStore | undefined = this.store;
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

  /** 导出文章 ↔ 标签关联（全表）。 */
  async allArticleTagsForBackup(): Promise<BackupArticleTag[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
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
    const store: relationalStore.RdbStore | undefined = this.store;
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
    }
    return added;
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
      hilog.error(DOMAIN, TAG, 'exec failed: %{public}d %{public}s', error.code, error.message);
    }
  }
}

/** 全局唯一实例。 */
export const articleStore: ArticleStore = new ArticleStore();
