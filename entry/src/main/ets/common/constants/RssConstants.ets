/*
 * RssConstants.ets — RSS 阅读器的纯逻辑常量。
 *
 * 超时、条数上限、文案截断长度等与设备环境无关，集中在这里；界面颜色 / 文案 / 尺寸一律走 resources。
 */
export class RssConstants {
  /** 建立连接超时（毫秒）。 */
  static readonly CONNECT_TIMEOUT_MS: number = 8000;
  /** 读取超时（毫秒）。 */
  static readonly READ_TIMEOUT_MS: number = 12000;
  /**
   * 每个订阅源最多解析的条目数。
   * 提到 100：不少站点一次就吐上百条，之前 40 条会让「最新」之外的内容永远看不到；
   * 代价是单次解析/入库更大，靠列表后续做分页 + 本地缓存上限兜住。
   */
  static readonly MAX_ARTICLES_PER_FEED: number = 100;
  /** 列表摘要最大字符数。 */
  static readonly SUMMARY_MAX_CHARS: number = 160;
  /** 请求 Accept 头：优先索取 feed 文档。 */
  static readonly ACCEPT_HEADER: string = 'application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml, */*';
}

/** 订阅源操作的结果码（视图据此映射到文案）。 */
export enum FeedError {
  NONE = 'none',
  EMPTY_URL = 'emptyUrl',
  DUPLICATE_URL = 'duplicateUrl',
  /** 请求超时（连接或读取超时）。 */
  TIMEOUT = 'timeout',
  /** 网络层失败：DNS 解析、连接不上、证书校验等。 */
  NETWORK_ERROR = 'networkError',
  /** 服务器返回非 2xx 状态码。 */
  HTTP_ERROR = 'httpError',
  /** 服务器返回空正文（地址往往不是有效订阅源，或需要登录）。 */
  EMPTY_RESPONSE = 'emptyResponse',
  /** 正文不是可解析的 RSS / Atom / JSON Feed。 */
  PARSE_ERROR = 'parseError',
  /** 用户给的地址既不是订阅源，页面里也没发现可订阅的链接（自动发现失败）。 */
  NOT_A_FEED = 'notAFeed',
  /** 兜底：未归类的抓取失败。 */
  FETCH_FAILED = 'fetchFailed'
}

/** 抓取失败时抛出的分类错误：携带结果码，供 ViewModel 映射到界面文案。 */
export class FeedFetchError extends Error {
  readonly code: FeedError;

  constructor(code: FeedError, message: string) {
    super(message);
    this.code = code;
  }
}

/** 文章 id 的分隔符（订阅源 id + 链接）。 */
export const ARTICLE_ID_SEPARATOR: string = '|';

/** 文章列表的筛选视图。 */
export enum ArticleFilter {
  ALL = 'all',
  UNREAD = 'unread',
  STARRED = 'starred',
  /** 稍后读（手动标记，永不自动归档）。 */
  SAVED = 'saved',
  /** 归档：已读且超过「归档规则」天数。 */
  ARCHIVED = 'archived'
}

/**
 * 文章列表分组方式。
 * NONE：平铺（按时间排一列）；FEED：按订阅源分组；DATE：按日期分组（今天/昨天/本周/更早）。
 */
export enum GroupMode {
  NONE = 'none',
  FEED = 'feed',
  DATE = 'date'
}

/** 详情页阅读模式：阅读器（正文提取）/ 网页原文。 */
export enum ReaderViewMode {
  READER = 'reader',
  WEB = 'web'
}

/** 首页筛选值归一：脏值一律退回「全部」。 */
export function normalizeArticleFilter(value: string): string {
  if (value === ArticleFilter.UNREAD || value === ArticleFilter.STARRED ||
    value === ArticleFilter.SAVED || value === ArticleFilter.ARCHIVED) {
    return value;
  }
  return ArticleFilter.ALL;
}

/** 阅读模式归一：脏值一律退回「阅读器」。 */
export function normalizeReaderViewMode(value: string): string {
  return value === ReaderViewMode.WEB ? ReaderViewMode.WEB : ReaderViewMode.READER;
}

/** 文章本地缓存（RDB）相关常量。 */
export class ArticleDbConstants {
  static readonly DB_NAME: string = 'harmony_rss.db';
  static readonly TABLE_ARTICLES: string = 'articles';
  /** 正文标注表（本地，无后端）。 */
  static readonly TABLE_HIGHLIGHTS: string = 'highlights';
  /** 全文检索虚表（FTS5：article_id / title / summary / plain_text / author）。 */
  static readonly TABLE_ARTICLES_FTS: string = 'articles_fts';
  /**
   * 中文检索虚表（FTS5：article_id UNINDEXED + grams）。
   * grams 是「CJK 单字 + 相邻二元组」的空格分隔 token 流，建表时显式 unicode61，
   * 保证预切分出来的 token 不会被二次切碎 —— 中文检索不再依赖设备的 ICU 分词能力。
   */
  static readonly TABLE_ARTICLES_FTS_CJK: string = 'articles_fts_cjk';
  /** 回收站（与 articles 同构 + deleted_at）：清理可撤销 7 天。 */
  static readonly TABLE_ARTICLES_TRASH: string = 'articles_trash';
  /** 标签表（id / name / name_key / created_at）。 */
  static readonly TABLE_TAGS: string = 'tags';
  /** 文章 ↔ 标签关联表（article_id + tag_id 联合主键）。 */
  static readonly TABLE_ARTICLE_TAGS: string = 'article_tags';
  /** 智能文件夹表（名称 + 检索语法原始串 + 排序位）。 */
  static readonly TABLE_SMART_FOLDERS: string = 'smart_folders';
  /** 远端账号表（单账号，但结构支持多条）。 */
  static readonly TABLE_REMOTE_ACCOUNTS: string = 'remote_accounts';
  /** 同步游标 / 时间戳（key → value）。 */
  static readonly TABLE_SYNC_STATE: string = 'sync_state';
  /** 远端文章 id ↔ 本地文章 id 映射。 */
  static readonly TABLE_REMOTE_ARTICLE_MAP: string = 'remote_article_map';
  /** 本地已读 / 收藏变更的待同步队列（同篇聚合）。 */
  static readonly TABLE_SYNC_OUTBOX: string = 'sync_outbox';
  /**
   * 当前数据库结构版本
   * （v1 = 初始表；v2 = 索引 + FTS + 回收站；v3 = 中文检索索引；v4 = 标签 + 智能文件夹；
   *   v5 = 远端账号 / 游标 / 映射 / 待同步队列）。
   */
  static readonly SCHEMA_VERSION: number = 5;
}

/** 远端同步（Google Reader API）的条数与超时常量。 */
export class RemoteSyncConstants {
  /** 文章列表每页条数（stream/contents 的 n）。 */
  static readonly PAGE_SIZE: number = 100;
  /** 单个订阅源单次同步最多翻页数（首次同步只用第一页，避免一次性拉爆）。 */
  static readonly MAX_PAGES_PER_FEED: number = 10;
  /** 单次同步最多新增的文章数（超出的留待下次）。 */
  static readonly MAX_ARTICLES_PER_SYNC: number = 2000;
  /** 状态回写每批条数（edit-tag）。 */
  static readonly WRITE_BATCH: number = 50;
  /** id 列表每页条数（stream/items/ids 的 n）。 */
  static readonly ID_LIST_PAGE: number = 1000;
  /** id 列表单次同步最多翻页数（防止账号未读数极大时无限翻页）。 */
  static readonly MAX_ID_PAGES: number = 20;
  /** 连接超时（毫秒）。 */
  static readonly CONNECT_TIMEOUT_MS: number = 10000;
  /** 读取超时（毫秒）。 */
  static readonly READ_TIMEOUT_MS: number = 20000;
  /** 远端服务类型（目前仅 Google Reader API）。 */
  static readonly SERVICE_TYPE_GREADER: string = 'greader';
  /** 默认 API 路径（用户只填域名 / 根路径时自动补全）。 */
  static readonly GREADER_DEFAULT_PATH: string = '/api/greader.php';
  /** 账号 id 前缀。 */
  static readonly ACCOUNT_ID_PREFIX: string = 'ra_';
  /** 自动同步间隔（分钟）取值：off / 15 / 30 / 60。 */
  static readonly AUTO_SYNC_OFF: string = 'off';
  static readonly AUTO_SYNC_15: string = '15';
  static readonly AUTO_SYNC_30: string = '30';
  static readonly AUTO_SYNC_60: string = '60';
}

/** 标签 / 智能文件夹的数量与长度上限（软上限：超限时界面给提示，不静默丢数据）。 */
export class TagConstants {
  /** 标签数量上限。 */
  static readonly MAX_TAGS: number = 100;
  /** 智能文件夹数量上限。 */
  static readonly MAX_SMART_FOLDERS: number = 50;
  /** 标签名最大字符数（归一后）。 */
  static readonly TAG_NAME_MAX: number = 32;
  /** 智能文件夹查询串最大字符数。 */
  static readonly SMART_FOLDER_QUERY_MAX: number = 512;
  /** 标签文章列表单页条数（轻量列 + 分页，避免一次读入过多行）。 */
  static readonly ARTICLES_PAGE_SIZE: number = 50;
}

/** 全文检索相关常量。 */
export class SearchConstants {
  /** 搜索结果单页条数。 */
  static readonly PAGE_SIZE: number = 30;
  /** 索引重建每批条数（分批写入，避免一次性长事务卡住读写）。 */
  static readonly REBUILD_BATCH: number = 200;
  /** 命中片段长度（字符）。 */
  static readonly SNIPPET_MAX_CHARS: number = 120;
  /** 搜索历史最多保留条数。 */
  static readonly HISTORY_MAX: number = 20;
  /** 搜索结果里 `from:` 允许的来源数量上限（防止签发过长 SQL）。 */
  static readonly MAX_FROM_VALUES: number = 8;
  /**
   * 单篇文档写入中文索引的 grams 字符上限（默认 20000）。
   * 超过后只索引前 N 个字符的 token，避免超长正文把索引体积放大到不可控。
   */
  static readonly CJK_GRAMS_MAX_CHARS: number = 20000;
  /** 检索路径（诊断用）：主 FTS 索引。 */
  static readonly PATH_FTS: string = 'fts';
  /** 检索路径（诊断用）：中文二元组索引。 */
  static readonly PATH_CJK: string = 'cjk';
  /** 检索路径（诊断用）：全表 LIKE 降级。 */
  static readonly PATH_LIKE: string = 'like';
  /** 诊断日志统一前缀。 */
  static readonly LOG_PREFIX: string = 'CJKIDX';
  /** 中文分词能力探针：临时表名。 */
  static readonly PROBE_TABLE: string = 'cjk_probe_fts';
  /** 中文分词能力探针：样本正文。 */
  static readonly PROBE_SAMPLE: string = '鸿蒙系统开发';
  /** 中文分词能力探针：样本查询词。 */
  static readonly PROBE_TERM: string = '鸿蒙';
}

/** 保留清理相关常量。 */
export class RetentionConstants {
  /** 两次自动清理之间的最小间隔（6 小时）。 */
  static readonly MIN_INTERVAL_MS: number = 6 * 60 * 60 * 1000;
  /** 回收站保留时长（7 天）。 */
  static readonly TRASH_TTL_MS: number = 7 * 24 * 60 * 60 * 1000;
  /** 一天的毫秒数。 */
  static readonly DAY_MS: number = 24 * 60 * 60 * 1000;
}

/** Reader 正文提取状态（Article.readerState）。 */
export enum ReaderState {
  NONE = 'none',
  LOADING = 'loading',
  READY = 'ready',
  FAILED = 'failed'
}

/** 正文提取 / 抓取的阈值（纯逻辑常量）。 */
export class ReaderConstants {
  /** 单篇 Reader HTML 长度上限，防止超长文档拖慢 Web 渲染。 */
  static readonly MAX_READER_HTML_CHARS: number = 500 * 1024;
  /** 正文抓取后进入提取前，允许的最大原始 HTML 长度（超出直接截断）。 */
  static readonly MAX_SOURCE_HTML_CHARS: number = 2 * 1024 * 1024;
  /** Readability 主容器打分阈值：低于此值退回「保留块结构」的兜底提取。 */
  static readonly MIN_CONTENT_SCORE: number = 20;
  /**
   * feed 自带正文直接可用的最小纯文本量（字符）。
   * 低于此值多半是「Article URL / Comments URL」这类摘要或链接堆，应联网抓原文。
   */
  static readonly MIN_FEED_BODY_CHARS: number = 160;
  /** feed 自带正文里链接文本的占比上限：超过说明是链接列表，不是正文。 */
  static readonly MAX_FEED_BODY_LINK_RATIO: number = 0.5;
  /** 单篇内联图片的 base64 字符上限（约 450KB 原图），超过则保留远程链接不缓存。 */
  static readonly MAX_INLINE_IMAGE_CHARS: number = 600 * 1024;
  /** 单篇内联图片总量上限（所有 data URI 合计）。 */
  static readonly MAX_INLINE_TOTAL_CHARS: number = 1200 * 1024;
  /** 单篇最多内联的图片张数。 */
  static readonly MAX_INLINE_IMAGES: number = 8;
}

/** OPML 导入 / 导出相关常量（文件格式的元数据，不是界面文案）。 */
export class OpmlConstants {
  static readonly DOC_TITLE: string = 'HarmonyRss';
  static readonly FILE_NAME: string = 'harmonyrss-subscriptions.opml';
  static readonly FILE_SUFFIX_FILTER: string = 'OPML|.opml';
  static readonly MIME_TYPE: string = 'text/x-opml';
}
