/*
 * Remote.ets — 远端服务（Google Reader API）领域模型。
 *
 * 这些对象只描述协议与同步状态，不持有界面状态；凭据（密码 / token）不在这里出现。
 */

/** 远端操作失败的可分类错误码（视图据此映射文案）。 */
export enum RemoteErrorCode {
  NONE = 'none',
  /** 网络不可达 / DNS / 连接超时。 */
  NETWORK = 'network',
  /** TLS 证书不受信任。 */
  TLS = 'tls',
  /** 401 / 403：账号密码错误或 token 失效。 */
  AUTH = 'auth',
  /** 404 或明确提示：服务端未开启 Google Reader API。 */
  API_DISABLED = 'apiDisabled',
  /** 429：被限流。 */
  RATE_LIMIT = 'rateLimit',
  /** 5xx：服务端错误。 */
  SERVER = 'server',
  /** 响应不是可解析的 JSON / 文本。 */
  PARSE = 'parse',
  /** 不允许的明文 http（用户未显式允许）。 */
  INSECURE_HTTP = 'insecureHttp',
  /** 表单缺项。 */
  EMPTY = 'empty',
  /** 已有同步在跑。 */
  BUSY = 'busy',
  /** 未连接账号。 */
  NOT_CONNECTED = 'notConnected'
}

/** 携带分类错误码的异常（与 FeedFetchError 同构）。 */
export class RemoteError extends Error {
  readonly code: RemoteErrorCode;

  constructor(code: RemoteErrorCode, message: string) {
    super(message);
    this.code = code;
  }
}

/** 远端账号（单账号使用，但表结构支持多条）。 */
export class RemoteAccount {
  id: string;
  /** 归一后的 API 基地址（含 /api/greader.php 或反代子路径）。 */
  baseUrl: string;
  username: string;
  /** 目前固定 'greader'。 */
  serviceType: string;
  enabled: boolean;
  createdAt: number;
  updatedAt: number;
  lastSyncAt: number;
  pendingCount: number;
  failureCount: number;
  lastError: string;

  constructor(id: string, baseUrl: string, username: string, serviceType: string = 'greader') {
    this.id = id;
    this.baseUrl = baseUrl;
    this.username = username;
    this.serviceType = serviceType;
    this.enabled = true;
    this.createdAt = Date.now();
    this.updatedAt = this.createdAt;
    this.lastSyncAt = 0;
    this.pendingCount = 0;
    this.failureCount = 0;
    this.lastError = '';
  }
}

/** 远端订阅源（id 已去掉 `feed/` 前缀，url 即订阅地址）。 */
export class RemoteFeed {
  remoteId: string;
  url: string;
  title: string;
  group: string;

  constructor(remoteId: string, url: string, title: string, group: string = '') {
    this.remoteId = remoteId;
    this.url = url;
    this.title = title;
    this.group = group;
  }
}

/** 远端文章（字段缺失时由解析层补默认值）。 */
export class RemoteArticle {
  remoteId: string;
  feedUrl: string;
  feedTitle: string;
  title: string;
  link: string;
  /** 纯文本摘要。 */
  summary: string;
  /** 纯文本正文（GReader 的 content/summary 去标签）。 */
  content: string;
  /** 原始 HTML 正文（如有）。 */
  contentHtml: string;
  /** 毫秒时间戳（协议给的是秒，解析层已换算）。 */
  publishedAt: number;
  author: string;
  read: boolean;
  starred: boolean;

  constructor(remoteId: string, feedUrl: string, feedTitle: string, title: string, link: string) {
    this.remoteId = remoteId;
    this.feedUrl = feedUrl;
    this.feedTitle = feedTitle;
    this.title = title;
    this.link = link;
    this.summary = '';
    this.content = '';
    this.contentHtml = '';
    this.publishedAt = 0;
    this.author = '';
    this.read = false;
    this.starred = false;
  }
}

/** 远端 id → 本地文章 id 的映射。 */
export class RemoteMapping {
  remoteId: string;
  articleId: string;
  feedId: string;

  constructor(remoteId: string, articleId: string, feedId: string) {
    this.remoteId = remoteId;
    this.articleId = articleId;
    this.feedId = feedId;
  }
}

/** 待同步队列的一行（同一篇文章的已读 / 收藏聚合在一条里）。 */
export class OutboxItem {
  articleId: string;
  /** 是否需要回写已读。 */
  setRead: boolean;
  readValue: boolean;
  /** 是否需要回写收藏。 */
  setStarred: boolean;
  starredValue: boolean;
  updatedAt: number;
  retries: number;
  lastError: string;

  constructor(articleId: string) {
    this.articleId = articleId;
    this.setRead = false;
    this.readValue = false;
    this.setStarred = false;
    this.starredValue = false;
    this.updatedAt = 0;
    this.retries = 0;
    this.lastError = '';
  }
}

/** 同步状态快照（账号页展示）。 */
export class SyncStatus {
  lastSyncAt: number;
  pending: number;
  failures: number;
  lastError: string;
  /** 当前阶段（'idle' | 'feeds' | 'articles' | 'push' | 'pull' | 'done'）。 */
  phase: string;

  constructor(lastSyncAt: number, pending: number, failures: number, lastError: string, phase: string) {
    this.lastSyncAt = lastSyncAt;
    this.pending = pending;
    this.failures = failures;
    this.lastError = lastError;
    this.phase = phase;
  }
}

/** 一次同步的汇总结果。 */
export class SyncResult {
  feedsAdded: number;
  articlesAdded: number;
  statesPushed: number;
  statesPulled: number;
  errors: string[];

  constructor() {
    this.feedsAdded = 0;
    this.articlesAdded = 0;
    this.statesPushed = 0;
    this.statesPulled = 0;
    this.errors = [];
  }
}

/** 连接结果：ok = false 时 code / message 说明原因。 */
export class RemoteConnectResult {
  ok: boolean;
  code: RemoteErrorCode;
  message: string;
  feedCount: number;
  /** 连接成功但首次同步失败时的提示（连接本身仍算成功）。 */
  syncError: string;

  constructor(ok: boolean, code: RemoteErrorCode, message: string, feedCount: number = 0) {
    this.ok = ok;
    this.code = code;
    this.message = message;
    this.feedCount = feedCount;
    this.syncError = '';
  }
}

/** 文章列表的一页（stream/contents）。 */
export class RemoteContentsPage {
  items: RemoteArticle[];
  continuation: string;

  constructor(items: RemoteArticle[], continuation: string) {
    this.items = items;
    this.continuation = continuation;
  }
}

/** id 列表的一页（stream/items/ids）。 */
export class RemoteIdPage {
  ids: string[];
  continuation: string;

  constructor(ids: string[], continuation: string) {
    this.ids = ids;
    this.continuation = continuation;
  }
}

/** 本地文章的状态快照（拉回远端状态时对比用）。 */
export class ArticleState {
  articleId: string;
  read: boolean;
  starred: boolean;

  constructor(articleId: string, read: boolean, starred: boolean) {
    this.articleId = articleId;
    this.read = read;
    this.starred = starred;
  }
}

/** 冲突决策结果（push-first：待同步的本地字段优先）。 */
export class StateDecision {
  read: boolean;
  starred: boolean;

  constructor(read: boolean, starred: boolean) {
    this.read = read;
    this.starred = starred;
  }
}

/** 一次 edit-tag 调用（同一远端 id 的增删标签合并成一条）。 */
export class EditTagOp {
  remoteId: string;
  addTags: string[];
  removeTags: string[];

  constructor(remoteId: string, addTags: string[], removeTags: string[]) {
    this.remoteId = remoteId;
    this.addTags = addTags;
    this.removeTags = removeTags;
  }
}

/** Google Reader 状态标签常量。 */
export class GReaderTags {
  static readonly BASE: string = 'user/-/state/com.google/';
  static readonly READ: string = 'user/-/state/com.google/read';
  static readonly STARRED: string = 'user/-/state/com.google/starred';
  static readonly READING_LIST: string = 'user/-/state/com.google/reading-list';
  static readonly READ_SUFFIX: string = '/state/com.google/read';
  static readonly STARRED_SUFFIX: string = '/state/com.google/starred';
}
