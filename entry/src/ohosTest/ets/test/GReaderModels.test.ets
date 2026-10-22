/*
 * GReaderModels.test.ets — Google Reader 协议解析的容错与错误映射。
 *
 * 覆盖：订阅 id 前缀 / 缺字段、文章缺标题时间作者、秒 → 毫秒、id 列表、ClientLogin 文本、
 * HTTP 状态与网络异常分类。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  classifyNetworkFailure,
  errorCodeForStatus,
  parseContents,
  parseIdPage,
  parseLoginAuth,
  parseSubscriptions,
  parseWriteToken
} from '../../../main/ets/service/remote/GReaderModels';
import { RemoteArticle, RemoteErrorCode, RemoteFeed, RemoteIdPage, RemoteContentsPage } from '../../../main/ets/model/Remote';

const SUBS_JSON: string =
  '{"subscriptions":[' +
  '{"id":"feed/https://a.com/rss","title":"A","categories":[{"label":"科技"}]},' +
  '{"id":"feed/https://b.com/rss"},' +
  '{"title":"no id"},' +
  '{"id":"https://c.com/rss","title":"C"}' +
  ']}';

const CONTENTS_JSON: string =
  '{"items":[' +
  '{"id":"tag:google.com,2005:reader/item/1","title":"One","published":1700000000,' +
  '"alternate":[{"href":"https://a.com/1"}],"summary":{"content":"<p>hello</p>"},' +
  '"author":"Ada","origin":{"streamId":"feed/https://a.com/rss","title":"A"},' +
  '"categories":["user/-/state/com.google/read","user/-/state/com.google/starred"]},' +
  '{"id":"tag:google.com,2005:reader/item/2","updated":1700000100},' +
  '{"title":"no id"}' +
  '],"continuation":"cont-1"}';

export default function gReaderModelsTest() {
  describe('GReaderModels', () => {
    it('subscriptions_parsed_tolerantly', 0, () => {
      const feeds: RemoteFeed[] = parseSubscriptions(SUBS_JSON);
      // 缺 id 的条目被跳过。
      expect(feeds.length).assertEqual(3);
      expect(feeds[0].remoteId).assertEqual('feed/https://a.com/rss');
      expect(feeds[0].url).assertEqual('https://a.com/rss');
      expect(feeds[0].title).assertEqual('A');
      expect(feeds[0].group).assertEqual('科技');
      // 缺 title / categories：标题回落为地址，分组为空。
      expect(feeds[1].title).assertEqual('https://b.com/rss');
      expect(feeds[1].group).assertEqual('');
      // 没有 feed/ 前缀也兼容。
      expect(feeds[2].url).assertEqual('https://c.com/rss');
    });

    it('subscriptions_malformed_json_empty', 0, () => {
      expect(parseSubscriptions('').length).assertEqual(0);
      expect(parseSubscriptions('not json').length).assertEqual(0);
      expect(parseSubscriptions('{"subscriptions":null}').length).assertEqual(0);
    });

    it('contents_fields_tolerant', 0, () => {
      const page: RemoteContentsPage = parseContents(CONTENTS_JSON);
      expect(page.items.length).assertEqual(2);
      expect(page.continuation).assertEqual('cont-1');
      const first: RemoteArticle = page.items[0];
      expect(first.remoteId).assertEqual('tag:google.com,2005:reader/item/1');
      expect(first.title).assertEqual('One');
      expect(first.link).assertEqual('https://a.com/1');
      // 秒 → 毫秒。
      expect(first.publishedAt).assertEqual(1700000000000);
      expect(first.author).assertEqual('Ada');
      expect(first.feedUrl).assertEqual('feed/https://a.com/rss');
      expect(first.feedTitle).assertEqual('A');
      expect(first.read).assertTrue();
      expect(first.starred).assertTrue();
      expect(first.summary.indexOf('hello') >= 0).assertTrue();
      // 缺 title / link / author / published：用 updated 兜底，标题回落为远端 id。
      const second: RemoteArticle = page.items[1];
      expect(second.title).assertEqual('tag:google.com,2005:reader/item/2');
      expect(second.link).assertEqual('');
      expect(second.author).assertEqual('');
      expect(second.publishedAt).assertEqual(1700000100000);
      expect(second.read).assertFalse();
      expect(second.starred).assertFalse();
    });

    it('contents_malformed_json_empty', 0, () => {
      expect(parseContents('{}').items.length).assertEqual(0);
      expect(parseContents('oops').items.length).assertEqual(0);
    });

    it('id_page_parsed', 0, () => {
      const page: RemoteIdPage = parseIdPage('{"itemRefs":[{"id":"a"},{"id":"b"},{"noid":1}],"continuation":2}');
      expect(page.ids.length).assertEqual(2);
      expect(page.ids[0]).assertEqual('a');
      expect(page.continuation).assertEqual('2');
      expect(parseIdPage('{}').ids.length).assertEqual(0);
    });

    it('login_auth_parsed', 0, () => {
      expect(parseLoginAuth('SID=s\nLSID=l\nAuth=token123')).assertEqual('token123');
      expect(parseLoginAuth('Auth= only')).assertEqual('only');
      expect(parseLoginAuth('<html>login</html>')).assertEqual('');
      expect(parseLoginAuth('')).assertEqual('');
    });

    it('write_token_trimmed', 0, () => {
      expect(parseWriteToken('  abc \n')).assertEqual('abc');
    });

    it('http_status_mapped', 0, () => {
      expect(errorCodeForStatus(401)).assertEqual(RemoteErrorCode.AUTH);
      expect(errorCodeForStatus(403)).assertEqual(RemoteErrorCode.AUTH);
      expect(errorCodeForStatus(404)).assertEqual(RemoteErrorCode.API_DISABLED);
      expect(errorCodeForStatus(429)).assertEqual(RemoteErrorCode.RATE_LIMIT);
      expect(errorCodeForStatus(503)).assertEqual(RemoteErrorCode.SERVER);
      expect(errorCodeForStatus(400)).assertEqual(RemoteErrorCode.SERVER);
      expect(errorCodeForStatus(200)).assertEqual(RemoteErrorCode.NONE);
    });

    it('network_failure_classified', 0, () => {
      expect(classifyNetworkFailure(2300028, 'Operation timeout')).assertEqual(RemoteErrorCode.NETWORK);
      expect(classifyNetworkFailure(2300060, 'SSL peer certificate')).assertEqual(RemoteErrorCode.TLS);
      expect(classifyNetworkFailure(2300007, 'certificate verify failed')).assertEqual(RemoteErrorCode.TLS);
    });
  });
}
