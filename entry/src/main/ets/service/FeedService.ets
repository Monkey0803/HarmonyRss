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

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FeedError, FeedFetchError, RssConstants } from '../common/constants/RssConstants';
import { ParsedFeed, parseFeed } from './RssParser';
import { parseJsonFeed } from './JsonFeedParser';

/** @ohos.net.http 的错误码 = 2300000 + curl 错误码。 */
const HTTP_ERROR_BASE: number = 2300000;
/** curl 28：操作超时。 */
const CURL_TIMEOUT: number = 28;

/** 把底层网络异常归类为可展示的错误类型（超时与其它网络故障区分开）。 */
function classifyRequestError(error: BusinessError): FeedError {
  return error.code === HTTP_ERROR_BASE + CURL_TIMEOUT ? FeedError.TIMEOUT : FeedError.NETWORK_ERROR;
}

/**
 * 读取响应头里的某个字段。
 * http 返回的 header 是 Object，且 key 的大小写不保证统一，先转成 Record 再按几种常见写法依次取
 * （ArkTS 不允许在 Object 上做动态属性访问，也不建议用 Object.keys 逐个比对）。
 */
function headerOf(response: http.HttpResponse, name: string): string {
  const headers: Record<string, string> = response.header as Record<string, string>;
  const candidates: string[] = [name, name.toLowerCase(), name.toUpperCase()];
  for (let i = 0; i < candidates.length; i += 1) {
    const value: string | undefined = headers[candidates[i]];
    if (value !== undefined && value.length > 0) {
      return value;
    }
  }
  return '';
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
    if (etag.length > 0) {
      header['If-None-Match'] = etag;
    }
    if (lastModified.length > 0) {
      header['If-Modified-Since'] = lastModified;
    }
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      connectTimeout: RssConstants.CONNECT_TIMEOUT_MS,
      readTimeout: RssConstants.READ_TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING,
      header: header
    };
    const request: http.HttpRequest = http.createHttp();
    try {
      let response: http.HttpResponse;
      try {
        response = await request.request(url, options);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        throw new FeedFetchError(classifyRequestError(error), 'network: ' + error.message);
      }
      const serverEtag: string = headerOf(response, 'ETag');
      const serverModified: string = headerOf(response, 'Last-Modified');
      const nextEtag: string = serverEtag.length > 0 ? serverEtag : etag;
      const nextModified: string = serverModified.length > 0 ? serverModified : lastModified;

      if (response.responseCode === http.ResponseCode.NOT_MODIFIED) {
        return new FeedFetchResult(true, undefined, '', nextEtag, nextModified);
      }
      if (response.responseCode !== http.ResponseCode.OK) {
        throw new FeedFetchError(FeedError.HTTP_ERROR, 'HTTP ' + response.responseCode.toString());
      }
      const raw: string | Object | ArrayBuffer = response.result;
      const body: string = typeof raw === 'string' ? raw : '';
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
    } finally {
      request.destroy();
    }
  }
}

export const feedService: FeedService = new FeedService();
