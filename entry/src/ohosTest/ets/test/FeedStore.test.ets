/*
 * FeedStore.test.ets — 订阅源落盘的旧记录兼容与脏值归一。
 *
 * 覆盖：旧记录缺新字段回退默认（启用 / 跟随全局）、非法枚举与负数归一、编码往返不丢新字段。
 */

import { describe, it, expect } from '@ohos/hypium';
import { decodeFeedRecords, encodeFeeds } from '../../../main/ets/service/FeedStore';
import { FeedSource } from '../../../main/ets/model/Feed';
import { FullTextMode, TriState } from '../../../main/ets/common/constants/SettingsConstants';

/** 旧版本（无单源设置字段）的落盘记录。 */
const LEGACY_JSON: string =
  '[{"title":"少数派","url":"https://sspai.com/feed","siteUrl":"https://sspai.com",' +
  '"group":"科技","etag":"W/1","lastModified":"Tue, 01 Jan 2026 00:00:00 GMT"}]';

export default function feedStoreTest() {
  describe('FeedStore', () => {
    it('legacy_record_uses_defaults', 0, () => {
      const feeds: FeedSource[] = decodeFeedRecords(LEGACY_JSON);
      expect(feeds.length).assertEqual(1);
      const feed: FeedSource = feeds[0];
      expect(feed.title).assertEqual('少数派');
      expect(feed.url).assertEqual('https://sspai.com/feed');
      expect(feed.group).assertEqual('科技');
      expect(feed.etag).assertEqual('W/1');
      // 新字段：旧记录一律回退默认，且不会被误停用。
      expect(feed.enabled).assertTrue();
      expect(feed.fetchIntervalMinutes).assertEqual(0);
      expect(feed.fullTextMode).assertEqual(FullTextMode.GLOBAL);
      expect(feed.retentionDays).assertEqual(0);
      expect(feed.notify).assertEqual(TriState.GLOBAL);
      expect(feed.markReadOnScroll).assertEqual(TriState.GLOBAL);
      expect(feed.failureCount).assertEqual(0);
      expect(feed.lastUpdated).assertEqual(0);
    });

    it('dirty_values_normalized', 0, () => {
      const json: string =
        '[{"title":"x","url":"https://x.com/feed","siteUrl":"","group":"","etag":"","lastModified":"",' +
        '"enabled":true,"fetchIntervalMinutes":7,"fullTextMode":"weird","retentionDays":42,' +
        '"notify":"yes","markReadOnScroll":"maybe","failureCount":-3,"lastUpdated":-9}]';
      const feeds: FeedSource[] = decodeFeedRecords(json);
      expect(feeds.length).assertEqual(1);
      const feed: FeedSource = feeds[0];
      expect(feed.fetchIntervalMinutes).assertEqual(0);
      expect(feed.fullTextMode).assertEqual(FullTextMode.GLOBAL);
      expect(feed.retentionDays).assertEqual(0);
      expect(feed.notify).assertEqual(TriState.GLOBAL);
      expect(feed.markReadOnScroll).assertEqual(TriState.GLOBAL);
      expect(feed.failureCount).assertEqual(0);
      expect(feed.lastUpdated).assertEqual(0);
    });

    it('valid_new_fields_kept', 0, () => {
      const json: string =
        '[{"title":"x","url":"https://x.com/feed","siteUrl":"","group":"","etag":"","lastModified":"",' +
        '"enabled":false,"fetchIntervalMinutes":60,"fullTextMode":"always","retentionDays":30,' +
        '"notify":"off","markReadOnScroll":"on","failureCount":3,"lastUpdated":1700000000000}]';
      const feed: FeedSource = decodeFeedRecords(json)[0];
      expect(feed.enabled).assertFalse();
      expect(feed.fetchIntervalMinutes).assertEqual(60);
      expect(feed.fullTextMode).assertEqual(FullTextMode.ALWAYS);
      expect(feed.retentionDays).assertEqual(30);
      expect(feed.notify).assertEqual(TriState.OFF);
      expect(feed.markReadOnScroll).assertEqual(TriState.ON);
      expect(feed.failureCount).assertEqual(3);
      expect(feed.lastUpdated).assertEqual(1700000000000);
    });

    it('drops_record_without_url', 0, () => {
      const json: string = '[{"title":"no url","url":"   "},{"title":"ok","url":"https://a.com/rss"}]';
      const feeds: FeedSource[] = decodeFeedRecords(json);
      expect(feeds.length).assertEqual(1);
      expect(feeds[0].url).assertEqual('https://a.com/rss');
    });

    it('encode_decode_roundtrip', 0, () => {
      const feed: FeedSource = new FeedSource('https://a.com/rss', 'A', 'https://a.com/rss', 'https://a.com', 'g');
      feed.enabled = false;
      feed.fetchIntervalMinutes = 180;
      feed.fullTextMode = FullTextMode.NEVER;
      feed.retentionDays = -1;
      feed.notify = TriState.ON;
      feed.markReadOnScroll = TriState.ON;
      feed.failureCount = 2;
      feed.lastUpdated = 1700000000001;
      const restored: FeedSource = decodeFeedRecords(encodeFeeds([feed]))[0];
      expect(restored.enabled).assertFalse();
      expect(restored.fetchIntervalMinutes).assertEqual(180);
      expect(restored.fullTextMode).assertEqual(FullTextMode.NEVER);
      // -1 = 该源永久保留。
      expect(restored.retentionDays).assertEqual(-1);
      expect(restored.notify).assertEqual(TriState.ON);
      expect(restored.markReadOnScroll).assertEqual(TriState.ON);
      expect(restored.failureCount).assertEqual(2);
      expect(restored.lastUpdated).assertEqual(1700000000001);
    });

    it('malformed_json_returns_empty', 0, () => {
      expect(decodeFeedRecords('not json').length).assertEqual(0);
      expect(decodeFeedRecords('').length).assertEqual(0);
    });
  });
}
