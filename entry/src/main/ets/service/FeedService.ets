/*
 * FeedService.ets — 抓取订阅源文档（Model 层：屏蔽平台网络能力）。
 *
 * 只负责「发请求 → 拿文本 → 交给解析器」，不做状态管理；网络/协议错误原样抛出给调用方决定降级。
 *
 * 条件请求：把上次响应的 ETag / Last-Modified 带上（If-None-Match / If-Modified-Since），
 * 服务器回 304 就直接判定「没有新内容」，不再下载整份文档（省流量、省电）。
 *
 * 解析失败**不抛异常**，而是返回 parsed = undefined 并把原文带回去 —— 调用方可能要用它做
 * 「feed 自动发现」（用户粘贴的是站点主页时，拿到的是一段 HTML）。
 */

import { FeedError, FeedFetchError, RssConstants } from '../common/constants/RssConstants';
import { ParsedFeed, parseFeed } from './RssParser';
import { parseJsonFeed } from './JsonFeedParser';
import {
  HttpError,
  HttpErrorKind,
  HttpOptions,
  HttpResponse,
  httpClient,
  setConditionalHeaders
} from './HttpClient';

/** 统一网络错误 → 抓取错误码（超时与其它网络故障区分开）。 */
function classifyRequestError(err: Object): FeedError {
  if (err instanceof HttpError) {
    return err.kind === HttpErrorKind.TIMEOUT ? FeedError.TIMEOUT : FeedError.NETWORK_ERROR;
  }
  return FeedError.NETWORK_ERROR;
}

/** 从异常里取可展示的描述。 */
function messageOf(err: Object): string {
  const error: Error = err as Error;
  return error.message !== undefined && error.message.length > 0 ? error.message : 'network failed';
}

/** 一次抓取的结果：可能「没变化」，也可能「拿到了文档但解析不出 feed」。 */
export class FeedFetchResult {
  /** 服务器回了 304：内容没变（此时 parsed 为 undefined）。 */
  readonly notModified: boolean;
  /** 解析成功的 feed；未变化或解析失败时为 undefined。 */
  readonly parsed: ParsedFeed | undefined;
  /** 原样文档文本（解析失败时交给自动发现扫描 <link>）；304 时为空串。 */
  readonly rawBody: string;
  /** 本次响应给出的校验值；服务器没给就沿用上一次的。 */
  readonly etag: string;
  readonly lastModified: string;

  constructor(notModified: boolean, parsed: ParsedFeed | undefined, rawBody: string,
    etag: string, lastModified: string) {
    this.notModified = notModified;
    this.parsed = parsed;
    this.rawBody = rawBody;
    this.etag = etag;
    this.lastModified = lastModified;
  }
}

/** 「用户输入的地址」解析出来的、真正可订阅的 feed（可能来自自动发现）。 */
export class ResolvedFeed {
  /** 实际要订阅的地址；与用户输入不同时说明是自动发现的。 */
  readonly url: string;
  readonly parsed: ParsedFeed;
  readonly etag: string;
  readonly lastModified: string;

  constructor(url: string, parsed: ParsedFeed, etag: string, lastModified: string) {
    this.url = url;
    this.parsed = parsed;
    this.etag = etag;
    this.lastModified = lastModified;
  }
}

export class FeedService {
  /**
   * 下载一个订阅地址。
   * @param etag / lastModified 上一次拿到的校验值，用于条件请求；没有就传空串。
   * @throws FeedFetchError 网络失败 / 超时 / 非 2xx / 空正文。
   */
  async fetchFeed(url: string, etag: string = '', lastModified: string = ''): Promise<FeedFetchResult> {
    const header: Record<string, string> = {};
    header['Accept'] = RssConstants.ACCEPT_HEADER;
    setConditionalHeaders(header, etag, lastModified);
    const options: HttpOptions = new HttpOptions();
    options.headers = header;
    options.connectTimeoutMs = RssConstants.CONNECT_TIMEOUT_MS;
    options.readTimeoutMs = RssConstants.READ_TIMEOUT_MS;
    let response: HttpResponse;
    try {
      response = await httpClient.getText(url, options);
    } catch (err) {
      throw new FeedFetchError(classifyRequestError(err), 'network: ' + messageOf(err));
    }
    const serverEtag: string = response.header('ETag');
    const serverModified: string = response.header('Last-Modified');
    const nextEtag: string = serverEtag.length > 0 ? serverEtag : etag;
    const nextModified: string = serverModified.length > 0 ? serverModified : lastModified;

    if (response.status === 304) {
      return new FeedFetchResult(true, undefined, '', nextEtag, nextModified);
    }
    if (response.status !== 200) {
      throw new FeedFetchError(FeedError.HTTP_ERROR, 'HTTP ' + response.status.toString());
    }
    const body: string = response.text;
    if (body.length === 0) {
      throw new FeedFetchError(FeedError.EMPTY_RESPONSE, 'empty response body');
    }
    // JSON Feed（application/feed+json）与 XML feed 在内容层区分，界面无感。
    let parsed: ParsedFeed | undefined = undefined;
    try {
      parsed = body.trim().startsWith('{') ? parseJsonFeed(body) : parseFeed(body);
    } catch (err) {
      parsed = undefined;
    }
    return new FeedFetchResult(false, parsed, body, nextEtag, nextModified);
  }
}

export const feedService: FeedService = new FeedService();
