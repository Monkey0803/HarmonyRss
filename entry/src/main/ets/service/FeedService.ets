/*
 * FeedService.ets — 抓取订阅源文档（Model 层：屏蔽平台网络能力）。
 *
 * 只负责「发请求 → 拿文本 → 交给解析器」，不做状态管理；错误原样抛出给 ViewModel 决定降级策略。
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

export class FeedService {
  /** 下载并解析一个订阅地址。失败时抛出 FeedFetchError（带结果码）。 */
  async fetchFeed(url: string): Promise<ParsedFeed> {
    const accept: Record<string, string> = { 'Accept': RssConstants.ACCEPT_HEADER };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      connectTimeout: RssConstants.CONNECT_TIMEOUT_MS,
      readTimeout: RssConstants.READ_TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING,
      header: accept
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
      if (response.responseCode !== http.ResponseCode.OK) {
        throw new FeedFetchError(FeedError.HTTP_ERROR, 'HTTP ' + response.responseCode.toString());
      }
      const raw: string | Object | ArrayBuffer = response.result;
      const body: string = typeof raw === 'string' ? raw : '';
      if (body.length === 0) {
        throw new FeedFetchError(FeedError.EMPTY_RESPONSE, 'empty response body');
      }
      // JSON Feed（application/feed+json）与 XML feed 在内容层区分，界面无感。
      try {
        return body.trim().startsWith('{') ? parseJsonFeed(body) : parseFeed(body);
      } catch (err) {
        throw new FeedFetchError(FeedError.PARSE_ERROR, 'unparsable feed document');
      }
    } finally {
      request.destroy();
    }
  }
}

export const feedService: FeedService = new FeedService();
