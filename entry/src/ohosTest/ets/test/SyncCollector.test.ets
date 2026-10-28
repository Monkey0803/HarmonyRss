/*
 * SyncCollector.test.ets — 同步差量采集的两个纯函数单测。
 *
 * 覆盖：
 *   - sameFeed：订阅源快照只比同步字段，任一字段变化都要判为「需要标脏」；
 *   - mergeSnapshot：值没变的字段保留旧时间戳（否则每同步一次就把旧状态刷成新时间，
 *     让对端误以为本地刚改过而覆盖回去），只有真正变化的字段才更新为 now。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ArticleStatePayload,
  FeedPayload,
  SyncField,
  SyncKinds,
  SyncRecord,
  encodeArticleStatePayload,
  encodeFeedPayload
} from '../../../main/ets/model/Sync';
import { mergeSnapshot, sameFeed } from '../../../main/ets/service/sync/SyncCollector';

function feedRecord(payload: FeedPayload): SyncRecord {
  return new SyncRecord('feed:https://example.com/feed', SyncKinds.FEED, 100, false,
    encodeFeedPayload(payload), 'node-a');
}

function statePayload(read: string, starred: string, saved: string, progress: string,
  at: number): ArticleStatePayload {
  return new ArticleStatePayload(new SyncField(read, at), new SyncField(starred, at),
    new SyncField(saved, at), new SyncField(progress, at));
}

export default function syncCollectorTest() {
  describe('SyncCollector', () => {
    // ---------- sameFeed ----------

    it('sameFeed_identical_payload', 0, () => {
      const payload: FeedPayload =
        new FeedPayload('https://example.com/feed', '标题', 'https://example.com', '科技', true);
      expect(sameFeed(feedRecord(payload), payload)).assertTrue();
    });

    it('sameFeed_detects_each_field', 0, () => {
      const base: FeedPayload =
        new FeedPayload('https://example.com/feed', '标题', 'https://example.com', '科技', true);
      const record: SyncRecord = feedRecord(base);
      expect(sameFeed(record, new FeedPayload('https://other.com/feed', '标题',
        'https://example.com', '科技', true))).assertFalse();
      expect(sameFeed(record, new FeedPayload('https://example.com/feed', '改名',
        'https://example.com', '科技', true))).assertFalse();
      expect(sameFeed(record, new FeedPayload('https://example.com/feed', '标题',
        'https://other.com', '科技', true))).assertFalse();
      expect(sameFeed(record, new FeedPayload('https://example.com/feed', '标题',
        'https://example.com', '设计', true))).assertFalse();
      expect(sameFeed(record, new FeedPayload('https://example.com/feed', '标题',
        'https://example.com', '科技', false))).assertFalse();
    });

    it('sameFeed_undefined_payload', 0, () => {
      // 墓碑（空载荷）与同步记录对不上时，一律按「需要写一条新记录」处理。
      const tombstone: SyncRecord = new SyncRecord('feed:https://example.com/feed',
        SyncKinds.FEED, 100, true, '', 'node-a');
      const payload: FeedPayload =
        new FeedPayload('https://example.com/feed', '标题', '', '', true);
      expect(sameFeed(tombstone, payload)).assertFalse();
    });

    // ---------- mergeSnapshot ----------

    it('mergeSnapshot_first_uses_now', 0, () => {
      const payload: ArticleStatePayload = mergeSnapshot(undefined, true, false, false, 0.5, 500);
      expect(payload.read.value).assertEqual('1');
      expect(payload.read.at).assertEqual(500);
      expect(payload.starred.value).assertEqual('0');
      expect(payload.saved.value).assertEqual('0');
      expect(payload.progress.value).assertEqual('0.5');
      expect(payload.progress.at).assertEqual(500);
    });

    it('mergeSnapshot_keeps_timestamps_when_nothing_changed', 0, () => {
      const prior: ArticleStatePayload = statePayload('1', '0', '1', '0.4', 100);
      const payload: ArticleStatePayload = mergeSnapshot(prior, true, false, true, 0.4, 900);
      // 值全都没变：时间戳必须原地不动，否则每次同步都会制造「假脏」。
      expect(payload.read.at).assertEqual(100);
      expect(payload.starred.at).assertEqual(100);
      expect(payload.saved.at).assertEqual(100);
      expect(payload.progress.at).assertEqual(100);
    });

    it('mergeSnapshot_bumps_only_changed_field', 0, () => {
      const prior: ArticleStatePayload = statePayload('0', '0', '0', '0.2', 100);
      const payload: ArticleStatePayload = mergeSnapshot(prior, true, false, false, 0.2, 900);
      expect(payload.read.value).assertEqual('1');
      expect(payload.read.at).assertEqual(900);
      // 没动的字段保持旧时间。
      expect(payload.starred.at).assertEqual(100);
      expect(payload.saved.at).assertEqual(100);
      expect(payload.progress.at).assertEqual(100);
    });

    it('mergeSnapshot_allows_going_back_to_false', 0, () => {
      // 取消已读 / 取消收藏同样是「变化」，必须带上新时间戳才能传播。
      const prior: ArticleStatePayload = statePayload('1', '1', '1', '1', 100);
      const payload: ArticleStatePayload = mergeSnapshot(prior, false, false, false, 0, 900);
      expect(payload.read.value).assertEqual('0');
      expect(payload.read.at).assertEqual(900);
      expect(payload.starred.value).assertEqual('0');
      expect(payload.starred.at).assertEqual(900);
      expect(payload.saved.at).assertEqual(900);
      expect(payload.progress.at).assertEqual(900);
    });

    it('mergeSnapshot_is_idempotent', 0, () => {
      const prior: ArticleStatePayload = statePayload('1', '0', '0', '0.6', 400);
      const once: ArticleStatePayload = mergeSnapshot(prior, false, false, false, 0.6, 900);
      const twice: ArticleStatePayload = mergeSnapshot(once, false, false, false, 0.6, 1200);
      // 第二轮值没变：不应再刷新时间戳，也不会被误判为脏。
      expect(encodeArticleStatePayload(twice)).assertEqual(encodeArticleStatePayload(once));
    });
  });
}
