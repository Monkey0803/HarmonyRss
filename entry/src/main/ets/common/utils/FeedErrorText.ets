/*
 * FeedErrorText.ets — 订阅错误码 → 界面文案的映射（订阅管理页与阅读页共用，避免两处漂移）。
 */
import { FeedError } from '../constants/RssConstants';

export class FeedErrorText {
  /** 把订阅结果码映射到对应的提示文案。 */
  static of(code: FeedError): ResourceStr {
    if (code === FeedError.EMPTY_URL) {
      return $r('app.string.err_empty_url');
    }
    if (code === FeedError.DUPLICATE_URL) {
      return $r('app.string.err_duplicate_url');
    }
    if (code === FeedError.TIMEOUT) {
      return $r('app.string.err_timeout');
    }
    if (code === FeedError.NETWORK_ERROR) {
      return $r('app.string.err_network');
    }
    if (code === FeedError.HTTP_ERROR) {
      return $r('app.string.err_http');
    }
    if (code === FeedError.EMPTY_RESPONSE) {
      return $r('app.string.err_empty_response');
    }
    if (code === FeedError.PARSE_ERROR) {
      return $r('app.string.err_parse');
    }
    if (code === FeedError.NOT_A_FEED) {
      return $r('app.string.err_not_a_feed');
    }
    return $r('app.string.err_fetch_failed');
  }
}
