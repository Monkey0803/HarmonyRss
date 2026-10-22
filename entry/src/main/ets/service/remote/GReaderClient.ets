/*
 * GReaderClient.ets — Google Reader API 的 HTTP 封装。
 *
 * 只负责「发请求 → 解析 → 分类错误」，不持有账号状态；token / 密码由上层传入。
 * 所有请求都有连接 / 读取超时；响应可能是字符串或 ArrayBuffer，统一转成文本。
 */

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  RemoteArticle,
  RemoteContentsPage,
  RemoteError,
  RemoteErrorCode,
  RemoteFeed,
  RemoteIdPage
} from '../../model/Remote';
import { RemoteSyncConstants } from '../../common/constants/RssConstants';
import {
  classifyNetworkFailure,
  errorCodeForStatus,
  looksLikeApiDisabled,
  parseContents,
  parseIdPage,
  parseLoginAuth,
  parseSubscriptions,
  parseWriteToken
} from './GReaderModels';

const DOMAIN: number = 0x0000;
const TAG: string = 'GReaderClient';

/** 探测结果：只要服务可达即 reachable，API 是否开启看 apiAvailable。 */
export class ProbeResult {
  reachable: boolean;
  apiAvailable: boolean;
  status: number;

  constructor(reachable: boolean, apiAvailable: boolean, status: number) {
    this.reachable = reachable;
    this.apiAvailable = apiAvailable;
    this.status = status;
  }
}

/** 一次 HTTP 响应（只保留状态码与文本正文）。 */
class TextResponse {
  status: number;
  body: string;

  constructor(status: number, body: string) {
    this.status = status;
    this.body = body;
  }
}

/** 响应体统一转文本：string 直接用；ArrayBuffer 按 UTF-8 解码。 */
function bodyToText(raw: string | Object | ArrayBuffer): string {
  if (typeof raw === 'string') {
    return raw.trim();
  }
  if (raw instanceof ArrayBuffer) {
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(raw)).trim();
    } catch (err) {
      return '';
    }
  }
  return '';
}

/** 去掉末尾斜杠。 */
function trimTrailingSlash(value: string): string {
  let result: string = value;
  while (result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

/**
 * Base URL 归一（纯函数）：
 *   1) 去空白、补 scheme（默认 https）；
 *   2) 去掉末尾斜杠；
 *   3) 路径为空 / 根路径时补 `/api/greader.php`；用户填了完整 / 反代子路径时原样保留。
 */
export function normalizeBaseUrl(input: string): string {
  let value: string = input.trim();
  if (value.length === 0) {
    return '';
  }
  const lower: string = value.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    value = 'https://' + value;
  }
  value = trimTrailingSlash(value);
  const schemeEnd: number = value.indexOf('://');
  if (schemeEnd < 0) {
    return '';
  }
  const pathStart: number = value.indexOf('/', schemeEnd + 3);
  if (pathStart < 0 || trimTrailingSlash(value.substring(pathStart)).length === 0) {
    return value + RemoteSyncConstants.GREADER_DEFAULT_PATH;
  }
  return value;
}

/** 是否是明文 http 地址。 */
export function isInsecureUrl(url: string): boolean {
  return url.toLowerCase().startsWith('http://');
}

/** 表单编码（空数组返回空串）。 */
function formEncode(pairs: string[]): string {
  return pairs.join('&');
}

/** 简单的 query 参数编码（值已 encodeURIComponent）。 */
function queryString(pairs: string[]): string {
  if (pairs.length === 0) {
    return '';
  }
  return '?' + pairs.join('&');
}

export class GReaderClient {
  /** 发一次请求；网络层异常转成分类 RemoteError。 */
  private async send(method: http.RequestMethod, url: string, headers: Record<string, string>,
    body: string = ''): Promise<TextResponse> {
    const options: http.HttpRequestOptions = {
      method: method,
      connectTimeout: RemoteSyncConstants.CONNECT_TIMEOUT_MS,
      readTimeout: RemoteSyncConstants.READ_TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING,
      header: headers
    };
    if (body.length > 0) {
      options.extraData = body;
    }
    const request: http.HttpRequest = http.createHttp();
    try {
      let response: http.HttpResponse;
      try {
        response = await request.request(url, options);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        const message: string = error.message !== undefined ? error.message : 'network failed';
        throw new RemoteError(classifyNetworkFailure(error.code, message), message);
      }
      return new TextResponse(response.responseCode, bodyToText(response.result));
    } finally {
      request.destroy();
    }
  }

  /** 认证头。 */
  private authHeader(auth: string): Record<string, string> {
    const header: Record<string, string> = {};
    header['Authorization'] = 'GoogleLogin auth=' + auth;
    return header;
  }

  /** 把非 2xx 响应转成分类异常。 */
  private ensureOk(response: TextResponse, context: string): void {
    if (response.status >= 200 && response.status < 300) {
      return;
    }
    const code: RemoteErrorCode = errorCodeForStatus(response.status);
    hilog.warn(DOMAIN, TAG, '%{public}s failed status=%{public}d code=%{public}s',
      context, response.status, code.toString());
    throw new RemoteError(code, context + ' HTTP ' + response.status.toString());
  }

  /** 探测服务是否可达 / GReader API 是否开启（未认证时 401 / 403 也算开启）。 */
  async probe(baseUrl: string): Promise<ProbeResult> {
    const url: string = baseUrl + '/reader/api/0/subscription/list' +
      queryString(['output=json']);
    const response: TextResponse = await this.send(http.RequestMethod.GET, url, {});
    if (response.status >= 200 && response.status < 300) {
      return new ProbeResult(true, true, response.status);
    }
    if (response.status === 401 || response.status === 403) {
      return new ProbeResult(true, true, response.status);
    }
    if (looksLikeApiDisabled(response.status, response.body)) {
      return new ProbeResult(true, false, response.status);
    }
    if (response.status >= 500) {
      throw new RemoteError(RemoteErrorCode.SERVER, 'probe HTTP ' + response.status.toString());
    }
    return new ProbeResult(true, false, response.status);
  }

  /** ClientLogin，返回 Auth token。 */
  async login(baseUrl: string, username: string, password: string): Promise<string> {
    const header: Record<string, string> = {};
    header['Content-Type'] = 'application/x-www-form-urlencoded';
    const body: string = formEncode([
      'Email=' + encodeURIComponent(username),
      'Passwd=' + encodeURIComponent(password)
    ]);
    const response: TextResponse = await this.send(http.RequestMethod.POST,
      baseUrl + '/accounts/ClientLogin', header, body);
    if (response.status === 401 || response.status === 403) {
      throw new RemoteError(RemoteErrorCode.AUTH, 'login rejected');
    }
    if (looksLikeApiDisabled(response.status, response.body)) {
      throw new RemoteError(RemoteErrorCode.API_DISABLED, 'greader api disabled');
    }
    this.ensureOk(response, 'login');
    const auth: string = parseLoginAuth(response.body);
    if (auth.length === 0) {
      // 200 但没有 Auth：多半是登录页 HTML 或 API 未开启。
      throw new RemoteError(RemoteErrorCode.AUTH, 'login response has no auth token');
    }
    return auth;
  }

  /** 订阅列表。 */
  async fetchSubscriptions(baseUrl: string, auth: string): Promise<RemoteFeed[]> {
    const url: string = baseUrl + '/reader/api/0/subscription/list' + queryString(['output=json']);
    const response: TextResponse = await this.send(http.RequestMethod.GET, url, this.authHeader(auth));
    this.ensureOk(response, 'subscriptions');
    return parseSubscriptions(response.body);
  }

  /**
   * 某订阅源的文章列表。
   * @param continuation 上一页返回的 continuation；首页传空串。
   */
  async fetchContents(baseUrl: string, auth: string, feedUrl: string,
    continuation: string, limit: number): Promise<RemoteContentsPage> {
    const params: string[] = ['n=' + limit.toString(), 'output=json'];
    if (continuation.length > 0) {
      params.push('c=' + encodeURIComponent(continuation));
    }
    const url: string = baseUrl + '/reader/api/0/stream/contents/feed/' +
      encodeURIComponent(feedUrl) + queryString(params);
    const response: TextResponse = await this.send(http.RequestMethod.GET, url, this.authHeader(auth));
    this.ensureOk(response, 'contents');
    return parseContents(response.body);
  }

  /** 未读 id（reading-list 排除已读）。 */
  async fetchUnreadIds(baseUrl: string, auth: string, continuation: string): Promise<RemoteIdPage> {
    const params: string[] = [
      'output=json',
      's=user/-/state/com.google/reading-list',
      'xt=user/-/state/com.google/read',
      'n=' + RemoteSyncConstants.ID_LIST_PAGE.toString()
    ];
    if (continuation.length > 0) {
      params.push('c=' + encodeURIComponent(continuation));
    }
    const url: string = baseUrl + '/reader/api/0/stream/items/ids' + queryString(params);
    const response: TextResponse = await this.send(http.RequestMethod.GET, url, this.authHeader(auth));
    this.ensureOk(response, 'unread ids');
    return parseIdPage(response.body);
  }

  /** 收藏 id。 */
  async fetchStarredIds(baseUrl: string, auth: string, continuation: string): Promise<RemoteIdPage> {
    const params: string[] = [
      'output=json',
      's=user/-/state/com.google/starred',
      'n=' + RemoteSyncConstants.ID_LIST_PAGE.toString()
    ];
    if (continuation.length > 0) {
      params.push('c=' + encodeURIComponent(continuation));
    }
    const url: string = baseUrl + '/reader/api/0/stream/items/ids' + queryString(params);
    const response: TextResponse = await this.send(http.RequestMethod.GET, url, this.authHeader(auth));
    this.ensureOk(response, 'starred ids');
    return parseIdPage(response.body);
  }

  /** 写操作 token。 */
  async fetchWriteToken(baseUrl: string, auth: string): Promise<string> {
    const url: string = baseUrl + '/reader/api/0/token';
    const response: TextResponse = await this.send(http.RequestMethod.GET, url, this.authHeader(auth));
    this.ensureOk(response, 'token');
    const token: string = parseWriteToken(response.body);
    if (token.length === 0) {
      throw new RemoteError(RemoteErrorCode.AUTH, 'empty write token');
    }
    return token;
  }

  /** 回写已读 / 收藏（一次可带多个 a / r 参数）。 */
  async editTag(baseUrl: string, auth: string, writeToken: string, remoteId: string,
    addTags: string[], removeTags: string[]): Promise<void> {
    await this.editTagMany(baseUrl, auth, writeToken, [remoteId], addTags, removeTags);
  }

  /**
   * 批量回写：同一组增删标签的多个远端 id 合并成一次请求（FreshRSS / TTRSS / Miniflux
   * 的 GReader 兼容层都支持重复 i 参数）。50 条回写因此只需个位数请求。
   */
  async editTagMany(baseUrl: string, auth: string, writeToken: string, remoteIds: string[],
    addTags: string[], removeTags: string[]): Promise<void> {
    if (remoteIds.length === 0) {
      return;
    }
    const header: Record<string, string> = {};
    header['Content-Type'] = 'application/x-www-form-urlencoded';
    header['Authorization'] = 'GoogleLogin auth=' + auth;
    const pairs: string[] = ['T=' + encodeURIComponent(writeToken)];
    for (let i = 0; i < remoteIds.length; i += 1) {
      pairs.push('i=' + encodeURIComponent(remoteIds[i]));
    }
    for (let i = 0; i < addTags.length; i += 1) {
      pairs.push('a=' + encodeURIComponent(addTags[i]));
    }
    for (let i = 0; i < removeTags.length; i += 1) {
      pairs.push('r=' + encodeURIComponent(removeTags[i]));
    }
    const response: TextResponse = await this.send(http.RequestMethod.POST,
      baseUrl + '/reader/api/0/edit-tag', header, formEncode(pairs));
    this.ensureOk(response, 'edit-tag');
  }

  /** 仅供诊断：把远端文章标题拼成日志用文本（不含凭据）。 */
  static describe(article: RemoteArticle): string {
    return article.remoteId + ' ' + article.title;
  }
}

export const gReaderClient: GReaderClient = new GReaderClient();
