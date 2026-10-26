/*
 * RemoteBackend.ets — 远端服务的通用适配层。
 *
 * 目标：把「同步编排」与具体协议解耦。当前实现：
 *   - GReaderBackend：Google Reader API（FreshRSS / Tiny Tiny RSS / Miniflux）；
 *   - FeedbinBackend：Feedbin REST API。
 *
 * 约定：
 *   - 所有方法只抛 RemoteError（分类错误），网络 / HTTP 细节留在各 Backend 内；
 *   - session.token 的语义由 Backend 决定（GReader 是 auth token，Feedbin 是 Basic base64）；
 *   - cursor 是不透明字符串：GReader 用毫秒时间戳，Feedbin 用 ISO 8601 的 created_at。
 */

import { RemoteArticle, RemoteFeed, RemoteIdPage } from '../../model/Remote';

/** 登录后的会话（不落盘；密码只在 Asset Store）。 */
export class RemoteSession {
  /** GReader：ClientLogin 的 Auth token；Feedbin：`email:password` 的 Base64。 */
  readonly token: string;

  constructor(token: string) {
    this.token = token;
  }
}

/** 某订阅源的一页文章。 */
export class RemoteArticlePage {
  readonly items: RemoteArticle[];
  /** 同一次同步内的下一页游标（GReader continuation / Feedbin page）。空串表示没有下一页。 */
  readonly continuation: string;
  /** 该页可推进到的持久化游标（由 Backend 比较语义决定）。 */
  readonly cursor: string;

  constructor(items: RemoteArticle[], continuation: string, cursor: string) {
    this.items = items;
    this.continuation = continuation;
    this.cursor = cursor;
  }
}

/** 中立的已读 / 收藏变更（一条对应本地 outbox 的一篇）。 */
export class RemoteStateChange {
  readonly remoteId: string;
  /** undefined = 本次不改已读。 */
  readonly read: boolean | undefined;
  /** undefined = 本次不改收藏。 */
  readonly starred: boolean | undefined;

  constructor(remoteId: string, read: boolean | undefined, starred: boolean | undefined) {
    this.remoteId = remoteId;
    this.read = read;
    this.starred = starred;
  }
}

/** 回写结果：applied / failed 都是远端 id，errors 是分类错误码文本。 */
export class RemotePushResult {
  readonly applied: string[];
  readonly failed: string[];
  readonly errors: string[];

  constructor(applied: string[], failed: string[], errors: string[]) {
    this.applied = applied;
    this.failed = failed;
    this.errors = errors;
  }
}

export interface RemoteBackend {
  /** 持久化在 RemoteAccount.serviceType 里的取值。 */
  readonly serviceType: string;
  /** 新建账号时建议的 API 根地址（Feedbin 有固定值；GReader 为空）。 */
  readonly defaultBaseUrl: string;

  /** 归一化用户输入的 API 根地址；非法返回空串。 */
  normalizeBaseUrl(input: string): string;

  /** 是否明文 HTTP（需要用户显式允许）。 */
  isInsecureUrl(value: string): boolean;

  /** 登录 / 校验凭据；失败抛 RemoteError。 */
  authenticate(baseUrl: string, username: string, password: string): Promise<RemoteSession>;

  /** 订阅列表。 */
  listSubscriptions(baseUrl: string, session: RemoteSession): Promise<RemoteFeed[]>;

  /**
   * 某订阅源的一页文章。
   * @param cursor 上次同步的持久化游标（空串 = 首次）
   * @param continuation 本次同步内的下一页游标（空串 = 第一页）
   */
  fetchArticlePage(baseUrl: string, session: RemoteSession, feed: RemoteFeed,
    cursor: string, continuation: string, limit: number): Promise<RemoteArticlePage>;

  /** 未读 id（分页语义与 GReader 一致；Feedbin 一次返回全部）。 */
  fetchUnreadIds(baseUrl: string, session: RemoteSession, continuation: string): Promise<RemoteIdPage>;

  /** 收藏 id。 */
  fetchStarredIds(baseUrl: string, session: RemoteSession, continuation: string): Promise<RemoteIdPage>;

  /** 回写已读 / 收藏；部分失败通过结果返回，鉴权失效直接抛 AUTH。 */
  pushStateChanges(baseUrl: string, session: RemoteSession,
    changes: RemoteStateChange[]): Promise<RemotePushResult>;

  /** 比较并选择更「新」的持久化游标（GReader 数字 / Feedbin ISO 字符串）。 */
  betterCursor(current: string, candidate: string): string;
}
