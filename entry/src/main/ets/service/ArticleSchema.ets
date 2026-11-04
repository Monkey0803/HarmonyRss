/* Shared article schema, SQL and result types. */
import { ArticleDbConstants } from '../common/constants/RssConstants';

export const DOMAIN: number = 0x0000;
export const TAG: string = 'ArticleStore';

/** 手动保存网页的结果；复用已有文章时 created 为 false。 */
export class SavedWebPageResult {
  readonly articleId: string;
  readonly created: boolean;

  constructor(articleId: string, created: boolean) {
    this.articleId = articleId;
    this.created = created;
  }
}

/** 正文相关列（列表不读，按需 loadBody）。 */
export const BODY_COLUMNS: string =
  'content, content_html, reader_html, plain_text, page_etag, page_last_modified';

/** 轻量列表列：不含任何正文 HTML / 纯文本。列名带 `a.` 前缀，调用方一律 `FROM articles a`。 */
const LIST_COMMON_COLUMNS: string =
  'a.id, a.feed_id, a.feed_title, a.title, a.link, a.summary, a.published_at, a.is_read, a.is_starred, a.is_saved,' +
  ' a.is_hidden, a.image_url, a.author, a.progress, a.progress_ratio,' +
  ' (CASE WHEN a.reader_html <> \'\' THEN 1 ELSE 0 END) AS has_reader,' +
  ' (CASE WHEN a.reader_html LIKE \'<!--hrv9-->%\' OR a.reader_html LIKE \'<!--hrv8-->%\' THEN \'full\'' +
  ' WHEN a.reader_html LIKE \'<!--hrv9p-->%\' THEN \'partial\'' +
  ' WHEN a.reader_html LIKE \'<!--hrv9t-->%\' THEN \'text\'' +
  ' ELSE \'none\' END) AS offline_state,' +
  ' a.canonical_id,' +
  // 媒体附件与音频进度：列表显示播客 / 视频标识，详情页恢复播放位置。
  ' a.enclosures, a.media_progress';

export const LIST_COLUMNS: string = LIST_COMMON_COLUMNS + ',' +
  // 组内来源数（含主条自己）：主条列表行据此显示「N 个来源」。
  ' (SELECT COUNT(*) FROM ' + ArticleDbConstants.TABLE_ARTICLES +
  ' d WHERE d.canonical_id = a.id) AS dup_count';

/** 首次加载时由 ArticleRepository 一次性填入来源数，避免每行执行相关子查询。 */
export const LIST_FAST_COLUMNS: string = LIST_COMMON_COLUMNS + ', 0 AS dup_count';

export const SQL_CREATE: string =
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
  'canonical_id TEXT NOT NULL DEFAULT \'\', ' +
  // v8 媒体附件（JSON）与音频播放进度（秒）。
  'enclosures TEXT NOT NULL DEFAULT \'[]\', ' +
  'media_progress INTEGER NOT NULL DEFAULT 0)';

/**
 * 标注表：一条 = 引文 + 可选备注 + 配色 + 定位信息。
 * 与 articles 分开存（一对多，且删文章时按 article_id 一起清），所以用独立 CREATE TABLE IF NOT EXISTS。
 */
export const SQL_CREATE_HIGHLIGHTS: string =
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
export const SQL_ADD_IMAGE: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN image_url TEXT NOT NULL DEFAULT \'\'';
export const SQL_ADD_AUTHOR: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN author TEXT NOT NULL DEFAULT \'\'';
/** 阅读进度（滚动位置，px）。 */
export const SQL_ADD_PROGRESS: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN progress INTEGER NOT NULL DEFAULT 0';
/** 阅读进度比例（0–1）：换排版后恢复位置用。 */
export const SQL_ADD_PROGRESS_RATIO: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN progress_ratio REAL NOT NULL DEFAULT 0';
/** feed 自带的 HTML 正文（content:encoded / Atom content / JSON Feed content_html）。 */
export const SQL_ADD_CONTENT_HTML: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN content_html TEXT NOT NULL DEFAULT \'\'';
/** 正文页协商缓存的两个校验器（条件请求用）。 */
export const SQL_ADD_PAGE_ETAG: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN page_etag TEXT NOT NULL DEFAULT \'\'';
export const SQL_ADD_PAGE_LAST_MODIFIED: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN page_last_modified TEXT NOT NULL DEFAULT \'\'';
/** Reader 正文的纯文本（提供搜索 / 复制 / 朗读复用）。 */
export const SQL_ADD_PLAIN_TEXT: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN plain_text TEXT NOT NULL DEFAULT \'\'';
/** 稍后读（老库补列）。 */
export const SQL_ADD_SAVED: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN is_saved INTEGER NOT NULL DEFAULT 0';
/** Reader 视图的结构化正文 HTML（提取 + 净化后）。 */
export const SQL_ADD_READER: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN reader_html TEXT NOT NULL DEFAULT \'\'';
/** 规则隐藏标记（v6）；老库补列，默认 0 = 未隐藏。 */
export const SQL_ADD_HIDDEN: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0';

/** 跨源去重 URL 归一化键（v7）；老库补列，默认空串 = 还没算过。 */
export const SQL_ADD_LINK_KEY: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN link_key TEXT NOT NULL DEFAULT \'\'';
/** 跨源去重标题归一化键（v7）。 */
export const SQL_ADD_TITLE_KEY: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN title_key TEXT NOT NULL DEFAULT \'\'';
/** 所属主条 id（v7）；空串 = 本条就是主条。 */
export const SQL_ADD_CANONICAL: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN canonical_id TEXT NOT NULL DEFAULT \'\'';
/** v8 媒体附件（JSON 数组）。 */
export const SQL_ADD_ENCLOSURES: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN enclosures TEXT NOT NULL DEFAULT \'[]\'';
/** v8 音频播放进度（秒）。 */
export const SQL_ADD_MEDIA_PROGRESS: string =
  'ALTER TABLE ' + ArticleDbConstants.TABLE_ARTICLES + ' ADD COLUMN media_progress INTEGER NOT NULL DEFAULT 0';

/** 入库去重：单批最多处理 / 查询的键数（避免 IN 列表过长）。 */
export const DEDUPE_KEY_BATCH: number = 200;

export const SQL_INSERT: string =
  'INSERT OR IGNORE INTO ' + ArticleDbConstants.TABLE_ARTICLES +
  ' (id, feed_id, feed_title, title, link, summary, content, published_at, is_read, is_starred, fetched_at,' +
  ' image_url, author, content_html, link_key, title_key, canonical_id, enclosures)' +
  ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

/** 备份导入：单事务最多处理的条数（2 万篇 ≈ 100 个短事务，避免长事务卡顿）。 */
export const BACKUP_BATCH_SIZE: number = 200;

/** 备份导出：文章段只取元数据 + 阅读状态列（不含正文缓存 / fetched_at）。 */
export const SQL_SELECT_BACKUP_ARTICLES: string =
  'SELECT id, feed_id, feed_title, title, link, summary, author, published_at, image_url,' +
  ' is_read, is_starred, is_saved, progress, progress_ratio, is_hidden,' +
  ' canonical_id, link_key, title_key FROM ' + ArticleDbConstants.TABLE_ARTICLES;

/** 备份导入：按 id 查已有文章的状态列（决定 INSERT 还是状态并集 UPDATE）。 */
export const SQL_SELECT_BACKUP_ARTICLE_STATE: string =
  'SELECT id, is_read, is_starred, is_saved, is_hidden, progress, progress_ratio, canonical_id FROM ' +
  ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?';

/** 备份导入新文章：正文列留空（首次打开时重新提取），fetched_at 记导入时间。 */
export const SQL_INSERT_BACKUP_ARTICLE: string =
  'INSERT INTO ' + ArticleDbConstants.TABLE_ARTICLES +
  ' (id, feed_id, feed_title, title, link, summary, content, published_at,' +
  ' is_read, is_starred, is_saved, is_hidden, fetched_at, image_url, author,' +
  ' progress, progress_ratio, link_key, title_key, canonical_id)' +
  ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

/** 备份导入已有文章：只并集状态列，不动标题 / 正文 / 来源等已有内容。 */
export const SQL_UPDATE_BACKUP_ARTICLE_STATE: string =
  'UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
  ' SET is_read = ?, is_starred = ?, is_saved = ?, is_hidden = ?, progress = ?,' +
  ' progress_ratio = ?, canonical_id = ? WHERE id = ?';

/** 备份导出：标注段全字段。 */
export const SQL_SELECT_BACKUP_HIGHLIGHTS: string =
  'SELECT id, article_id, quote, note, color, created_at, anchor_text, anchor_ratio FROM ' +
  ArticleDbConstants.TABLE_HIGHLIGHTS;

/** 备份导入标注：主键相同即忽略（幂等，不覆盖本地备注 / 配色）。 */
export const SQL_INSERT_BACKUP_HIGHLIGHT: string =
  'INSERT OR IGNORE INTO ' + ArticleDbConstants.TABLE_HIGHLIGHTS +
  ' (id, article_id, quote, note, color, created_at, anchor_text, anchor_ratio)' +
  ' VALUES (?, ?, ?, ?, ?, ?, ?, ?)';

/** 备份导出：文章 ↔ 标签关联全表。 */
export const SQL_SELECT_BACKUP_ARTICLE_TAGS: string =
  'SELECT article_id, tag_id FROM ' + ArticleDbConstants.TABLE_ARTICLE_TAGS;

/** 备份导入关联：联合主键相同即忽略（幂等）。 */
export const SQL_INSERT_BACKUP_ARTICLE_TAG: string =
  'INSERT OR IGNORE INTO ' + ArticleDbConstants.TABLE_ARTICLE_TAGS +
  ' (article_id, tag_id) VALUES (?, ?)';

/** 列表：轻量列，按发布时间倒序；只取主条（重复项不进主表列表）。 */
export const SQL_SELECT_LIST: string =
  'SELECT ' + LIST_FAST_COLUMNS + ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a' +
  ' WHERE a.canonical_id = \'\' ORDER BY a.published_at DESC';

/**
 * 摘要数据源：某时刻之后入库、仍未读、未隐藏、非重复项的轻量行。
 * 用 fetched_at（入库时间）而不是发布时间：摘要描述的是「今天新到的」。
 */
export const SQL_SELECT_FETCHED_SINCE: string =
  'SELECT ' + LIST_COLUMNS + ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a' +
  ' WHERE a.fetched_at >= ? AND a.is_read = 0 AND a.is_hidden = 0 AND a.canonical_id = \'\'' +
  ' ORDER BY a.published_at DESC';

/** 正文：按 id 取。 */
export const SQL_SELECT_BODY: string =
  'SELECT ' + BODY_COLUMNS + ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a WHERE a.id = ?';

/** 回收站表与主表同构 + deleted_at。 */
export const SQL_CREATE_TRASH: string =
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
export const SQL_INDEXES: string[] = [
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
export const SQL_CREATE_TAGS: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_TAGS + ' (' +
  'id TEXT PRIMARY KEY, ' +
  'name TEXT NOT NULL, ' +
  'name_key TEXT NOT NULL UNIQUE, ' +
  'created_at INTEGER NOT NULL DEFAULT 0)';

/**
 * v10 订阅源表：从偏好库 JSON 迁进 RDB。
 * 偏好库适合「少量设置」，但订阅有几百条时每次全量读改写 JSON 会越来越慢。
 * 过渡期双写（RDB + 偏好库），偏好库保留一版用于回滚与降级。
 */
export const SQL_CREATE_FEEDS: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_FEEDS + ' (' +
  'id TEXT PRIMARY KEY, ' +
  'url TEXT NOT NULL DEFAULT \'\', ' +
  'title TEXT NOT NULL DEFAULT \'\', ' +
  'site_url TEXT NOT NULL DEFAULT \'\', ' +
  'feed_group TEXT NOT NULL DEFAULT \'\', ' +
  'etag TEXT NOT NULL DEFAULT \'\', ' +
  'last_modified TEXT NOT NULL DEFAULT \'\', ' +
  'last_updated INTEGER NOT NULL DEFAULT 0, ' +
  'last_error TEXT NOT NULL DEFAULT \'\', ' +
  'last_error_code TEXT NOT NULL DEFAULT \'\', ' +
  'enabled INTEGER NOT NULL DEFAULT 1, ' +
  'fetch_interval INTEGER NOT NULL DEFAULT 0, ' +
  'full_text_mode TEXT NOT NULL DEFAULT \'global\', ' +
  'retention_days INTEGER NOT NULL DEFAULT 0, ' +
  'notify TEXT NOT NULL DEFAULT \'global\', ' +
  'mark_read_on_scroll TEXT NOT NULL DEFAULT \'global\', ' +
  'failure_count INTEGER NOT NULL DEFAULT 0, ' +
  'position INTEGER NOT NULL DEFAULT 0)';

/**
 * v4 文章 ↔ 标签关联表：联合主键保证「同一标签重复添加不产生重复关联」。
 * 关联行随文章删除 / 回收站过期清除而清理，但移入 / 移出回收站时**保留**（恢复后标签仍在）。
 */
export const SQL_CREATE_ARTICLE_TAGS: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_ARTICLE_TAGS + ' (' +
  'article_id TEXT NOT NULL, ' +
  'tag_id TEXT NOT NULL, ' +
  'PRIMARY KEY (article_id, tag_id))';

/** v4 智能文件夹表：只存检索语法原始串 + 手动排序位。 */
export const SQL_CREATE_SMART_FOLDERS: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_SMART_FOLDERS + ' (' +
  'id TEXT PRIMARY KEY, ' +
  'name TEXT NOT NULL, ' +
  'query TEXT NOT NULL, ' +
  'sort_order INTEGER NOT NULL DEFAULT 0, ' +
  'created_at INTEGER NOT NULL DEFAULT 0, ' +
  'updated_at INTEGER NOT NULL DEFAULT 0)';

/** v4 索引：按标签反查文章（复合）、智能文件夹排序。 */
export const SQL_INDEXES_V4: string[] = [
  'CREATE INDEX IF NOT EXISTS idx_article_tags_tag ON ' +
    ArticleDbConstants.TABLE_ARTICLE_TAGS + '(tag_id, article_id)',
  'CREATE INDEX IF NOT EXISTS idx_smart_folders_order ON ' +
    ArticleDbConstants.TABLE_SMART_FOLDERS + '(sort_order)'
];

/**
 * v5 远端账号表：只存地址 / 账号 / 状态，密码在 Asset Store。
 * failure_count / last_error 支持「连续失败次数与最近错误」可观测。
 */
export const SQL_CREATE_REMOTE_ACCOUNTS: string =
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
export const SQL_CREATE_SYNC_STATE: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_SYNC_STATE + ' (' +
  'key TEXT PRIMARY KEY, ' +
  'value TEXT NOT NULL DEFAULT \'\')';

/** v5 远端文章映射：远端 id → 本地文章 id（本地 id 由 buildArticleId 生成）。 */
export const SQL_CREATE_REMOTE_MAP: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_REMOTE_ARTICLE_MAP + ' (' +
  'remote_id TEXT PRIMARY KEY, ' +
  'article_id TEXT NOT NULL, ' +
  'feed_id TEXT NOT NULL, ' +
  'updated_at INTEGER NOT NULL DEFAULT 0)';

/** v5 待同步队列：同一篇文章聚合为一行（已读 / 收藏各带目标值）。 */
export const SQL_CREATE_SYNC_OUTBOX: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_SYNC_OUTBOX + ' (' +
  'article_id TEXT PRIMARY KEY, ' +
  'set_read INTEGER NOT NULL DEFAULT 0, ' +
  'read_value INTEGER NOT NULL DEFAULT 0, ' +
  'set_starred INTEGER NOT NULL DEFAULT 0, ' +
  'starred_value INTEGER NOT NULL DEFAULT 0, ' +
  'updated_at INTEGER NOT NULL DEFAULT 0, ' +
  'retries INTEGER NOT NULL DEFAULT 0, ' +
  'last_error TEXT NOT NULL DEFAULT \'\')';

/** v9 云同步记录：key 为实体稳定键；dirty = 1 表示还待推送；rev 为已拉到的远端版本。 */
export const SQL_CREATE_SYNC_RECORDS: string =
  'CREATE TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_SYNC_RECORDS + ' (' +
  'key TEXT PRIMARY KEY, ' +
  'kind TEXT NOT NULL DEFAULT \'\', ' +
  'payload TEXT NOT NULL DEFAULT \'\', ' +
  'updated_at INTEGER NOT NULL DEFAULT 0, ' +
  'deleted INTEGER NOT NULL DEFAULT 0, ' +
  'dirty INTEGER NOT NULL DEFAULT 0, ' +
  'origin TEXT NOT NULL DEFAULT \'\', ' +
  'rev TEXT NOT NULL DEFAULT \'\')';

export const SQL_INDEXES_V9: string[] = [
  'CREATE INDEX IF NOT EXISTS idx_sync_records_dirty ON ' +
    ArticleDbConstants.TABLE_SYNC_RECORDS + '(dirty, updated_at)',
  'CREATE INDEX IF NOT EXISTS idx_sync_records_kind ON ' +
    ArticleDbConstants.TABLE_SYNC_RECORDS + '(kind)'
];

/** v5 索引：按本地文章反查远端 id（回写状态 / 拉回状态都要用）。 */
export const SQL_INDEXES_V5: string[] = [
  'CREATE INDEX IF NOT EXISTS idx_remote_map_article ON ' +
    ArticleDbConstants.TABLE_REMOTE_ARTICLE_MAP + '(article_id)'
];

/**
 * v6 规则表：关键词 / 来源 / 标签用 JSON 字符串数组存（脏数据读取端容错），
 * 字段 / 动作用逗号串（值域固定）。
 */
export const SQL_CREATE_RULES: string =
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
export const SQL_INDEXES_V6: string[] = [
  'CREATE INDEX IF NOT EXISTS idx_rules_priority ON ' +
    ArticleDbConstants.TABLE_RULES + '(priority, created_at)'
];

/**
 * v7 索引：按归一化键找已有文章（入库去重）、按主条取组内成员（列表来源数 / 组操作）。
 * link_key / title_key 上的空串行不参与匹配（查询只给非空键，索引里空串只会被跳过）。
 */
export const SQL_INDEXES_V7: string[] = [
  'CREATE INDEX IF NOT EXISTS idx_articles_link_key ON ' +
    ArticleDbConstants.TABLE_ARTICLES + '(link_key)',
  'CREATE INDEX IF NOT EXISTS idx_articles_title_key ON ' +
    ArticleDbConstants.TABLE_ARTICLES + '(title_key, published_at)',
  'CREATE INDEX IF NOT EXISTS idx_articles_canonical ON ' +
    ArticleDbConstants.TABLE_ARTICLES + '(canonical_id)'
];

/** 远端映射写入（重复调用覆盖更新时间）。 */
export const SQL_UPSERT_REMOTE_MAP: string =
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

/** 摘要回填的一条待写记录（先收集再统一写库，避免遍历 ResultSet 时并发写同一连接）。 */
export class SummaryFix {
  readonly id: string;
  readonly summary: string;

  constructor(id: string, summary: string) {
    this.id = id;
    this.summary = summary;
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
export function placeholders(count: number): string {
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
