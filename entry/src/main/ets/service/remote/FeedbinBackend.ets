/*
 * FeedbinBackend.ets — Feedbin REST API 的 RemoteBackend 适配器。
 *
 * 协议要点（https://github.com/feedbin/feedbin-api）：
 *   - Base: https://api.feedbin.com/v2/；HTTP Basic（email:password）；
 *   - 订阅：GET /subscriptions.json；
 *   - 文章：GET /feeds/{feed_id}/entries.json（page / per_page=100，since 用 created_at ISO）；
 *   - 状态：GET unread_entries / starred_entries；回写用 POST 批量端点（不用 DELETE，兼容代理）。
 *
 * 游标使用服务器返回的 created_at ISO 字符串（entries 按 created_at 倒序）。
 */

import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  RemoteError,
  RemoteErrorCode,
  RemoteFeed,
  RemoteIdPage
} from '../../model/Remote';
import { RemoteSyncConstants } from '../../common/constants/RssConstants';
import {
  HttpError,
  HttpMethod,
  HttpOptions,
  HttpResponse,
  httpClient
} from '../HttpClient';
import { classifyNetworkFailure, errorCodeForStatus } from './GReaderModels';
import {
  betterIsoCursor,
  FEEDBIN_DEFAULT_BASE,
  feedbinApiUrl,
  normalizeFeedbinBaseUrl,
  parseFeedbinEntries,
  parseFeedbinFeedOptions,
  parseFeedbinIds,
  parseFeedbinSubscriptions
} from './FeedbinModels';
import {
  RemoteArticlePage,
  RemoteBackend,
  RemotePushResult,
  RemoteSession,
  RemoteStateChange
} from './RemoteBackend';

const DOMAIN: number = 0x0000;
const TAG: string = 'FeedbinBackend';
/** Feedbin 单次批量状态回写上限。 */
const FEEDBIN_BATCH: number = 1000;

class TextResponse {
  readonly status: number;
  readonly body: string;
  /** X-Feedbin-Record-Count；-1 表示响应没带这个头。 */
  readonly recordCount: number;

  constructor(status: number, body: string, recordCount: number) {
    this.status = status;
    this.body = body;
    this.recordCount = recordCount;
  }
}

function codeOf(err: Object): RemoteErrorCode {
  return err instanceof RemoteError ? err.code : RemoteErrorCode.SERVER;
}

function isNumericId(value: string): boolean {
  return /^[0-9]+$/.test(value);
}

export class FeedbinBackend implements RemoteBackend {
  readonly serviceType: string = RemoteSyncConstants.SERVICE_TYPE_FEEDBIN;
  readonly defaultBaseUrl: string = FEEDBIN_DEFAULT_BASE;

  normalizeBaseUrl(input: string): string {
    return normalizeFeedbinBaseUrl(input);
  }

  isInsecureUrl(value: string): boolean {
    return value.toLowerCase().startsWith('http://');
  }

  /** Feedbin 没有独立登录端点：先构造 Basic 凭据，首个订阅请求负责校验。 */
  async authenticate(baseUrl: string, username: string, password: string): Promise<RemoteSession> {
    if (username.trim().length === 0 || password.length === 0) {
      throw new RemoteError(RemoteErrorCode.EMPTY, 'missing credentials');
    }
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(username.trim() + ':' + password);
    return new RemoteSession(new util.Base64Helper().encodeToStringSync(bytes));
  }

  async listSubscriptions(baseUrl: string, session: RemoteSession): Promise<RemoteFeed[]> {
    const response: TextResponse = await this.get(baseUrl, '/subscriptions.json', session);
    this.ensureOk(response, 'subscriptions');
    const feeds: RemoteFeed[] = parseFeedbinSubscriptions(response.body);
    if (feeds.length === 0 && response.body.trim() !== '[]') {
      // 200 但不是数组 / 解析失败：多半不是 Feedbin 实例或代理返回了 HTML。
      throw new RemoteError(RemoteErrorCode.PARSE, 'invalid subscriptions response');
    }
    return feeds;
  }

  async fetchArticlePage(baseUrl: string, session: RemoteSession, feed: RemoteFeed,
    cursor: string, continuation: string, limit: number): Promise<RemoteArticlePage> {
    const feedId: string = feed.remoteId;
    if (feedId.length === 0) {
      return new RemoteArticlePage([], '', cursor);
    }
    const page: number = continuation.length > 0 ? Number.parseInt(continuation, 10) : 1;
    const safePage: number = Number.isNaN(page) || page < 1 ? 1 : page;
    const safeLimit: number = limit > 100 ? 100 : (limit <= 0 ? 100 : limit);
    let path: string = '/feeds/' + encodeURIComponent(feedId) + '/entries.json?per_page=' +
      safeLimit.toString() + '&page=' + safePage.toString();
    if (cursor.length > 0) {
      path += '&since=' + encodeURIComponent(cursor);
    }
    let response: TextResponse;
    try {
      response = await this.get(baseUrl, path, session);
    } catch (err) {
      // 文档明确：页码不存在时返回 404。已经有第一页数据时，把「没有下一页」当空页处理。
      if (safePage > 1 && codeOf(err) === RemoteErrorCode.API_DISABLED) {
        return new RemoteArticlePage([], '', cursor);
      }
      if (err instanceof RemoteError) {
        throw err;
      }
      throw new RemoteError(RemoteErrorCode.SERVER, 'entries failed');
    }
    this.ensureOk(response, 'entries');
    const entriesBody: string = response.body.trim();
    if (entriesBody.length > 0 && !entriesBody.startsWith('[')) {
      throw new RemoteError(RemoteErrorCode.PARSE, 'invalid entries response');
    }
    const result: RemoteArticlePage = parseFeedbinEntries(entriesBody, feed, cursor);
    let next: string = '';
    if (response.recordCount >= 0) {
      next = response.recordCount > safePage * safeLimit ? (safePage + 1).toString() : '';
    } else if (result.items.length >= safeLimit) {
      next = (safePage + 1).toString();
    }
    return new RemoteArticlePage(result.items, next, result.cursor);
  }

  async fetchUnreadIds(baseUrl: string, session: RemoteSession, continuation: string): Promise<RemoteIdPage> {
    const response: TextResponse = await this.get(baseUrl, '/unread_entries.json', session);
    this.ensureOk(response, 'unread entries');
    this.ensureIdListBody(response, 'unread entries');
    return new RemoteIdPage(parseFeedbinIds(response.body), '');
  }

  async fetchStarredIds(baseUrl: string, session: RemoteSession, continuation: string): Promise<RemoteIdPage> {
    const response: TextResponse = await this.get(baseUrl, '/starred_entries.json', session);
    this.ensureOk(response, 'starred entries');
    this.ensureIdListBody(response, 'starred entries');
    return new RemoteIdPage(parseFeedbinIds(response.body), '');
  }

  async subscribeFeed(baseUrl: string, session: RemoteSession, feedUrl: string): Promise<void> {
    const target: string = feedUrl.trim();
    if (target.length === 0) {
      throw new RemoteError(RemoteErrorCode.EMPTY, 'empty feed url');
    }
    let response: TextResponse = await this.postJson(baseUrl, '/subscriptions.json', session,
      this.subscribeBody(target));
    if (response.status === 300) {
      const options: string[] = parseFeedbinFeedOptions(response.body);
      if (options.length === 0) {
        throw new RemoteError(RemoteErrorCode.SUBSCRIPTION_FAILED, 'multiple choices without feed_url');
      }
      response = await this.postJson(baseUrl, '/subscriptions.json', session,
        this.subscribeBody(options[0]));
    }
    if (response.status >= 200 && response.status < 300) {
      return;
    }
    if (response.status === 302) {
      return;
    }
    const code: RemoteErrorCode = errorCodeForStatus(response.status);
    if (code === RemoteErrorCode.AUTH || code === RemoteErrorCode.RATE_LIMIT
      || code === RemoteErrorCode.SERVER) {
      throw new RemoteError(code, 'subscribe HTTP ' + response.status.toString());
    }
    throw new RemoteError(RemoteErrorCode.SUBSCRIPTION_FAILED,
      'subscribe HTTP ' + response.status.toString());
  }

  /** Feedbin 的创建订阅请求体（feed_url 只含常规 URL 字符，这里仍转义引号 / 反斜杠）。 */
  private subscribeBody(feedUrl: string): string {
    const escaped: string = feedUrl.split('\\').join('\\\\').split('"').join('\\"');
    return '{"feed_url":"' + escaped + '"}';
  }

  async pushStateChanges(baseUrl: string, session: RemoteSession,
    changes: RemoteStateChange[]): Promise<RemotePushResult> {
    const readTrue: string[] = [];
    const readFalse: string[] = [];
    const starredTrue: string[] = [];
    const starredFalse: string[] = [];
    for (let i = 0; i < changes.length; i += 1) {
      const change: RemoteStateChange = changes[i];
      if (!isNumericId(change.remoteId)) {
        continue;
      }
      if (change.read === true) {
        readTrue.push(change.remoteId);
      } else if (change.read === false) {
        readFalse.push(change.remoteId);
      }
      if (change.starred === true) {
        starredTrue.push(change.remoteId);
      } else if (change.starred === false) {
        starredFalse.push(change.remoteId);
      }
    }
    const failedSet: Set<string> = new Set();
    const attemptedSet: Set<string> = new Set();
    const errors: string[] = [];
    const markAttempted = (list: string[]): void => {
      for (let i = 0; i < list.length; i += 1) {
        attemptedSet.add(list[i]);
      }
    };
    markAttempted(readTrue);
    markAttempted(readFalse);
    markAttempted(starredTrue);
    markAttempted(starredFalse);
    try {
      await this.pushBucket(baseUrl, session, '/unread_entries/delete.json', 'unread_entries',
        readTrue, failedSet, errors);
      await this.pushBucket(baseUrl, session, '/unread_entries.json', 'unread_entries',
        readFalse, failedSet, errors);
      await this.pushBucket(baseUrl, session, '/starred_entries.json', 'starred_entries',
        starredTrue, failedSet, errors);
      await this.pushBucket(baseUrl, session, '/starred_entries/delete.json', 'starred_entries',
        starredFalse, failedSet, errors);
    } catch (err) {
      // pushBucket 已经把该批 id 记为失败并写入错误码；鉴权失效直接上抛给同步服务。
      const code: RemoteErrorCode = codeOf(err);
      if (code === RemoteErrorCode.AUTH) {
        throw new RemoteError(code, 'auth expired during push');
      }
      errors.push(code.toString());
    }
    const applied: string[] = [];
    const failed: string[] = [];
    for (let i = 0; i < changes.length; i += 1) {
      const id: string = changes[i].remoteId;
      if (failedSet.has(id)) {
        failed.push(id);
      } else if (attemptedSet.has(id)) {
        applied.push(id);
      }
    }
    return new RemotePushResult(applied, failed, errors);
  }

  betterCursor(current: string, candidate: string): string {
    return betterIsoCursor(current, candidate);
  }

  /** 一个动作桶：分批发送；响应里缺失 / 请求失败的 id 记为失败。 */
  private async pushBucket(baseUrl: string, session: RemoteSession, path: string, key: string,
    ids: string[], failedSet: Set<string>, errors: string[]): Promise<void> {
    for (let offset = 0; offset < ids.length; offset += FEEDBIN_BATCH) {
      const batch: string[] = ids.slice(offset, offset + FEEDBIN_BATCH);
      if (batch.length === 0) {
        continue;
      }
      const body: string = '{"' + key + '":[' + batch.join(',') + ']}';
      try {
        const response: TextResponse = await this.postJson(baseUrl, path, session, body);
        this.ensureOk(response, 'state push');
        const bodyText: string = response.body.trim();
        if (bodyText.length === 0 || !bodyText.startsWith('[')) {
          // 2xx 但没有逐 id 响应：视为整批成功，避免因代理改写响应导致无限重试。
          continue;
        }
        const returned: string[] = parseFeedbinIds(bodyText);
        for (let i = 0; i < batch.length; i += 1) {
          if (returned.indexOf(batch[i]) < 0) {
            failedSet.add(batch[i]);
          }
        }
      } catch (err) {
        const code: RemoteErrorCode = codeOf(err);
        for (let i = 0; i < batch.length; i += 1) {
          failedSet.add(batch[i]);
        }
        errors.push(code.toString());
        if (code === RemoteErrorCode.AUTH) {
          throw new RemoteError(code, 'auth expired during push');
        }
      }
    }
  }

  /** 未读 / 收藏接口必须返回 JSON 数组；空正文视为异常，避免把本地状态误判成「全部已读」。 */
  private ensureIdListBody(response: TextResponse, context: string): void {
    const body: string = response.body.trim();
    if (body.length === 0 || !body.startsWith('[')) {
      throw new RemoteError(RemoteErrorCode.PARSE, 'invalid ' + context + ' response');
    }
  }

  private authHeader(session: RemoteSession): Record<string, string> {
    const header: Record<string, string> = {};
    header['Authorization'] = 'Basic ' + session.token;
    return header;
  }

  private async get(baseUrl: string, path: string, session: RemoteSession): Promise<TextResponse> {
    const header: Record<string, string> = {};
    header['Accept'] = 'application/json';
    const auth: Record<string, string> = this.authHeader(session);
    const keys: string[] = Object.keys(auth);
    for (let i = 0; i < keys.length; i += 1) {
      header[keys[i]] = auth[keys[i]];
    }
    return this.send(HttpMethod.GET, feedbinApiUrl(baseUrl, path), header);
  }

  private async postJson(baseUrl: string, path: string, session: RemoteSession,
    body: string): Promise<TextResponse> {
    const header: Record<string, string> = {};
    header['Accept'] = 'application/json';
    header['Content-Type'] = 'application/json; charset=utf-8';
    const auth: Record<string, string> = this.authHeader(session);
    const keys: string[] = Object.keys(auth);
    for (let i = 0; i < keys.length; i += 1) {
      header[keys[i]] = auth[keys[i]];
    }
    return this.send(HttpMethod.POST, feedbinApiUrl(baseUrl, path), header, body);
  }

  private async send(method: HttpMethod, requestUrl: string, headers: Record<string, string>,
    body: string = ''): Promise<TextResponse> {
    const options: HttpOptions = new HttpOptions();
    options.headers = headers;
    options.body = body;
    options.connectTimeoutMs = RemoteSyncConstants.CONNECT_TIMEOUT_MS;
    options.readTimeoutMs = RemoteSyncConstants.READ_TIMEOUT_MS;
    // 状态回写是幂等的（重复标记已读 / 收藏没有副作用），允许统一层重试一次。
    options.maxRetries = 1;
    let response: HttpResponse;
    try {
      response = await httpClient.request(method, requestUrl, options);
    } catch (err) {
      if (err instanceof HttpError) {
        throw new RemoteError(classifyNetworkFailure(err.causeCode, err.message), err.message);
      }
      const error: BusinessError = err as BusinessError;
      const message: string = error.message !== undefined ? error.message : 'network failed';
      throw new RemoteError(classifyNetworkFailure(error.code, message), message);
    }
    const countText: string = response.header('X-Feedbin-Record-Count');
    const count: number = countText.length > 0 ? Number.parseInt(countText, 10) : -1;
    return new TextResponse(response.status, response.text.trim(), Number.isNaN(count) ? -1 : count);
  }

  private ensureOk(response: TextResponse, context: string): void {
    if (response.status >= 200 && response.status < 300) {
      return;
    }
    const code: RemoteErrorCode = errorCodeForStatus(response.status);
    hilog.warn(DOMAIN, TAG, '%{public}s failed status=%{public}d code=%{public}s',
      context, response.status, code.toString());
    throw new RemoteError(code, context + ' HTTP ' + response.status.toString());
  }
}

export const feedbinBackend: FeedbinBackend = new FeedbinBackend();
