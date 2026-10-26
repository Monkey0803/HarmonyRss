/*
 * HttpClient.test.ets — 统一网络层纯函数单测。
 *
 * 覆盖：
 *   - 指数退避与上限；
 *   - 主机键提取（scheme / host / port / userinfo / query）；
 *   - 可重试状态（429 / 5xx）；
 *   - Retry-After 解析与上限；
 *   - 条件请求头只在校验值非空时添加；
 *   - 默认重试次数按方法区分；
 *   - 响应头大小写不敏感读取。
 *
 * 不发真实网络请求。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  defaultRetries,
  backoffMs,
  hostKeyOf,
  HttpDefaults,
  HttpMethod,
  HttpResponse,
  parseRetryAfterMs,
  setConditionalHeaders,
  shouldRetryStatus
} from '../../../main/ets/service/HttpClient';

export default function httpClientTest() {
  describe('HttpClient', () => {
    it('backoff_is_exponential_and_capped', 0, () => {
      expect(backoffMs(0)).assertEqual(HttpDefaults.BASE_BACKOFF_MS);
      expect(backoffMs(1)).assertEqual(HttpDefaults.BASE_BACKOFF_MS * 2);
      expect(backoffMs(2)).assertEqual(HttpDefaults.BASE_BACKOFF_MS * 4);
      // 继续翻倍会超过上限 → 夹到上限。
      expect(backoffMs(10)).assertEqual(HttpDefaults.MAX_BACKOFF_MS);
      // 非法值按 0 处理。
      expect(backoffMs(Number.NaN)).assertEqual(HttpDefaults.BASE_BACKOFF_MS);
      expect(backoffMs(-3)).assertEqual(HttpDefaults.BASE_BACKOFF_MS);
    });

    it('host_key_extracts_authority', 0, () => {
      expect(hostKeyOf('https://example.com/feed.xml')).assertEqual('example.com');
      expect(hostKeyOf('HTTPS://Example.COM:8443/feed.xml?x=1')).assertEqual('example.com:8443');
      expect(hostKeyOf('http://user:pass@example.com/a')).assertEqual('example.com');
      expect(hostKeyOf('https://example.com?x=1')).assertEqual('example.com');
      expect(hostKeyOf('not a url')).assertEqual('');
    });

    it('retry_status_only_429_and_5xx', 0, () => {
      expect(shouldRetryStatus(429)).assertTrue();
      expect(shouldRetryStatus(500)).assertTrue();
      expect(shouldRetryStatus(503)).assertTrue();
      expect(shouldRetryStatus(401)).assertFalse();
      expect(shouldRetryStatus(404)).assertFalse();
      expect(shouldRetryStatus(304)).assertFalse();
    });

    it('retry_after_parses_seconds_and_caps', 0, () => {
      expect(parseRetryAfterMs('2', 400)).assertEqual(2000);
      expect(parseRetryAfterMs('0', 400)).assertEqual(0);
      expect(parseRetryAfterMs('', 400)).assertEqual(400);
      expect(parseRetryAfterMs('abc', 400)).assertEqual(400);
      expect(parseRetryAfterMs('-1', 400)).assertEqual(400);
      // 超过上限时夹到 MAX_RETRY_AFTER_MS。
      expect(parseRetryAfterMs('999', 400)).assertEqual(HttpDefaults.MAX_RETRY_AFTER_MS);
    });

    it('conditional_headers_only_when_present', 0, () => {
      const headers: Record<string, string> = {};
      setConditionalHeaders(headers, 'etag-1', 'Mon, 01 Jan 2026 00:00:00 GMT');
      expect(headers['If-None-Match']).assertEqual('etag-1');
      expect(headers['If-Modified-Since']).assertEqual('Mon, 01 Jan 2026 00:00:00 GMT');

      const empty: Record<string, string> = {};
      setConditionalHeaders(empty, '', '');
      expect(empty['If-None-Match'] ?? '').assertEqual('');
      expect(empty['If-Modified-Since'] ?? '').assertEqual('');
    });

    it('default_retries_by_method', 0, () => {
      expect(defaultRetries(HttpMethod.GET)).assertEqual(1);
      expect(defaultRetries(HttpMethod.HEAD)).assertEqual(1);
      expect(defaultRetries(HttpMethod.POST)).assertEqual(0);
    });

    it('response_header_is_case_insensitive', 0, () => {
      const headers: Record<string, string> = { 'etag': 'abc', 'Content-Type': 'text/xml' };
      const response: HttpResponse = new HttpResponse(200, headers, '<rss/>', undefined);
      expect(response.header('ETag')).assertEqual('abc');
      expect(response.header('etag')).assertEqual('abc');
      expect(response.header('content-type')).assertEqual('text/xml');
      expect(response.header('missing')).assertEqual('');
    });
  });
}
