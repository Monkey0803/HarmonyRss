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
  STARRED = 'starred'
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
  if (value === ArticleFilter.UNREAD || value === ArticleFilter.STARRED) {
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
  /** 缓存上限：超过后清理最旧的未收藏文章（收藏的永不清理）。 */
  static readonly MAX_CACHED_ARTICLES: number = 1000;
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
