/*
 * FeedbinModels.test.ets — Feedbin 协议解析与游标语义单测。
 *
 * 覆盖：订阅列表、文章（null 字段容错 / created_at 游标）、id 数组、API 地址归一、
 * ISO 游标比较，以及 GReader 数字游标不被 ISO 语义污染。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  betterIsoCursor,
  feedbinApiUrl,
  isoMillis,
  normalizeFeedbinBaseUrl,
  parseFeedbinEntries,
  parseFeedbinFeedOptions,
  parseFeedbinIds,
  parseFeedbinSubscriptions
} from '../../../main/ets/service/remote/FeedbinModels';
import { RemoteArticlePage } from '../../../main/ets/service/remote/RemoteBackend';
import { RemoteFeed } from '../../../main/ets/model/Remote';
import { feedbinBackend } from '../../../main/ets/service/remote/FeedbinBackend';
import { gReaderBackend } from '../../../main/ets/service/remote/GReaderBackend';

const SUBSCRIPTIONS: string =
  '[{"id":525,"feed_id":47,"title":"Daring Fireball",' +
  '"feed_url":"https://daringfireball.net/feeds/main","site_url":"https://daringfireball.net/"},' +
  '{"id":526,"feed_id":48,"title":null,' +
  '"feed_url":"https://example.com/feed.xml","site_url":null}]';

const ENTRIES: string =
  '[{"id":2077,"feed_id":135,"title":"Objective-C Runtime Releases",' +
  '"url":"https://example.com/a","author":null,' +
  '"content":"<p>Hello <b>world</b></p>","summary":null,' +
  '"published":"2013-02-03T01:00:19.000000Z","created_at":"2013-02-04T01:00:19.127893Z"},' +
  '{"id":2076,"feed_id":135,"title":null,"url":"https://example.com/b","author":"A",' +
  '"content":null,"summary":"<p>Summary only</p>",' +
  '"published":"2013-02-02T01:00:19.000000Z","created_at":"2013-02-03T01:00:19.127893Z"}]';

export default function feedbinModelsTest() {
  describe('FeedbinModels', () => {
    it('parse_subscriptions', 0, () => {
      const feeds: RemoteFeed[] = parseFeedbinSubscriptions(SUBSCRIPTIONS);
      expect(feeds.length).assertEqual(2);
      expect(feeds[0].remoteId).assertEqual('47');
      expect(feeds[0].url).assertEqual('https://daringfireball.net/feeds/main');
      expect(feeds[0].title).assertEqual('Daring Fireball');
      expect(feeds[1].title).assertEqual('https://example.com/feed.xml');
    });

    it('parse_entries_null_fields_and_cursor', 0, () => {
      const feed: RemoteFeed = new RemoteFeed('135', 'https://example.com/feed.xml', 'Example', '');
      const page: RemoteArticlePage = parseFeedbinEntries(ENTRIES, feed, '');
      expect(page.items.length).assertEqual(2);
      expect(page.items[0].remoteId).assertEqual('2077');
      expect(page.items[0].title).assertEqual('Objective-C Runtime Releases');
      expect(page.items[0].contentHtml.indexOf('<b>world</b>') >= 0).assertTrue();
      expect(page.items[0].content.indexOf('Hello world') >= 0).assertTrue();
      expect(page.items[1].title).assertEqual('https://example.com/b');
      expect(page.items[1].summary.indexOf('Summary only') >= 0).assertTrue();
      expect(page.cursor).assertEqual('2013-02-04T01:00:19.127893Z');
      expect(page.items[0].read).assertFalse();
      expect(page.items[0].starred).assertFalse();
      expect(page.items[0].publishedAt).assertEqual(isoMillis('2013-02-03T01:00:19.000000Z'));
    });


    it('parse_feed_options_for_300', 0, () => {
      const options: string[] = parseFeedbinFeedOptions(
        '[{"feed_url":"https://github.com/blog.atom","title":"Blog"},' +
        '{"feed_url":"https://github.com/blog/broadcasts.atom","title":"Broadcasts"}]');
      expect(options.length).assertEqual(2);
      expect(options[0]).assertEqual('https://github.com/blog.atom');
      expect(parseFeedbinFeedOptions('not json').length).assertEqual(0);
    });

    it('parse_ids_and_api_url', 0, () => {
      const ids: string[] = parseFeedbinIds('[4089,4090,4091]');
      expect(ids.length).assertEqual(3);
      expect(ids[0]).assertEqual('4089');
      expect(parseFeedbinIds('not json').length).assertEqual(0);
      expect(feedbinApiUrl('https://api.feedbin.com/', '/subscriptions.json'))
        .assertEqual('https://api.feedbin.com/v2/subscriptions.json');
      expect(feedbinApiUrl('https://api.feedbin.com/v2', '/entries.json'))
        .assertEqual('https://api.feedbin.com/v2/entries.json');
    });

    it('normalize_base_url', 0, () => {
      expect(normalizeFeedbinBaseUrl('')).assertEqual('https://api.feedbin.com');
      expect(normalizeFeedbinBaseUrl('api.feedbin.com/')).assertEqual('https://api.feedbin.com');
      expect(normalizeFeedbinBaseUrl('https://feedbin.example.com/v2/'))
        .assertEqual('https://feedbin.example.com');
      expect(normalizeFeedbinBaseUrl('   ')).assertEqual('https://api.feedbin.com');
    });

    it('iso_cursor_comparison', 0, () => {
      expect(betterIsoCursor('', '2013-02-04T01:00:19.127893Z'))
        .assertEqual('2013-02-04T01:00:19.127893Z');
      expect(betterIsoCursor('2013-02-04T01:00:19.127893Z', '2013-02-03T01:00:19.127893Z'))
        .assertEqual('2013-02-04T01:00:19.127893Z');
      expect(betterIsoCursor('2013-02-03T01:00:19.127893Z', '2013-02-04T01:00:19.127893Z'))
        .assertEqual('2013-02-04T01:00:19.127893Z');
      expect(betterIsoCursor('2013-01-01T00:00:00Z', '')).assertEqual('2013-01-01T00:00:00Z');
    });

    it('backend_cursor_semantics', 0, () => {
      expect(feedbinBackend.betterCursor('2013-02-03T00:00:00Z', '2013-02-04T00:00:00Z'))
        .assertEqual('2013-02-04T00:00:00Z');
      expect(gReaderBackend.betterCursor('999', '1000')).assertEqual('1000');
      expect(gReaderBackend.betterCursor('1000', '999')).assertEqual('1000');
      expect(gReaderBackend.betterCursor('', '0')).assertEqual('');
    });
  });
}
