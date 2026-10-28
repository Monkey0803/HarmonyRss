/*
 * SyncMerge.test.ets — 云同步记录合并（纯函数）单测。
 *
 * 覆盖：
 *   - mergeField：时间戳优先、同时间戳时读 / 写标志取「真」、数值取大；
 *   - mergeRecord：订阅源整体 LWW、平局按 origin 收敛、墓碑（删除）同样参与比较；
 *   - 文章状态字段级合并：A 端标已读 + B 端打星标，两端都保留（不互相覆盖）；
 *   - isSameRecord：内容 / 时间 / 删除位任一不同即视为不同。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ArticleStatePayload,
  FeedPayload,
  SyncField,
  SyncKinds,
  SyncRecord,
  encodeArticleStatePayload,
  encodeFeedPayload,
  mergeField,
  mergeRecord,
  isSameRecord,
  pickNewer
} from '../../../main/ets/model/Sync';

function field(value: string, at: number): SyncField {
  return new SyncField(value, at);
}

function stateRecord(read: string, starred: string, readAt: number, starredAt: number,
  origin: string): SyncRecord {
  const payload = new ArticleStatePayload(field(read, readAt), field(starred, starredAt),
    field('0', 0), field('0', 0));
  return new SyncRecord('article:1', SyncKinds.ARTICLE_STATE, Math.max(readAt, starredAt),
    false, encodeArticleStatePayload(payload), origin);
}

function feedRecord(title: string, at: number, origin: string, deleted: boolean = false): SyncRecord {
  const payload = new FeedPayload('https://example.com/feed', title, '', '', true);
  return new SyncRecord('feed:https://example.com/feed', SyncKinds.FEED, at, deleted,
    deleted ? '' : encodeFeedPayload(payload), origin);
}

function readState(record: SyncRecord): ArticleStatePayload {
  const payload: ArticleStatePayload = JSON.parse(record.payload) as ArticleStatePayload;
  return payload;
}

export default function syncMergeTest() {
  describe('SyncMerge', () => {
    // ---------- mergeField ----------

    it('mergeField_newer_timestamp_wins', 0, () => {
      expect(mergeField(field('1', 100), field('0', 200)).value).assertEqual('0');
      expect(mergeField(field('1', 300), field('0', 200)).value).assertEqual('1');
    });

    it('mergeField_tie_prefers_true', 0, () => {
      // 同一毫秒：已读 / 收藏不能被旧快照回滚，取 true。
      expect(mergeField(field('0', 100), field('1', 100)).value).assertEqual('1');
      expect(mergeField(field('1', 100), field('0', 100)).value).assertEqual('1');
    });

    it('mergeField_tie_prefers_larger_number', 0, () => {
      expect(mergeField(field('0.2', 100), field('0.8', 100)).value).assertEqual('0.8');
      expect(mergeField(field('0.8', 100), field('0.2', 100)).value).assertEqual('0.8');
    });

    // ---------- pickNewer / mergeRecord（订阅源） ----------

    it('mergeRecord_feed_last_write_wins', 0, () => {
      const local: SyncRecord = feedRecord('Local', 100, 'node-a');
      const remote: SyncRecord = feedRecord('Remote', 200, 'node-b');
      const merged: SyncRecord = mergeRecord(local, remote);
      expect(merged.updatedAt).assertEqual(200);
      expect(merged.origin).assertEqual('node-b');
    });

    it('mergeRecord_feed_tie_breaks_by_origin', 0, () => {
      // 同一时间戳时按节点 id 字典序，两端算出的结果一致（否则会互相来回覆盖）。
      const local: SyncRecord = feedRecord('Local', 100, 'node-a');
      const remote: SyncRecord = feedRecord('Remote', 100, 'node-b');
      expect(mergeRecord(local, remote).origin).assertEqual('node-b');
      expect(mergeRecord(remote, local).origin).assertEqual('node-b');
      expect(pickNewer(remote, local).origin).assertEqual('node-b');
    });

    it('mergeRecord_tombstone_wins_when_newer', 0, () => {
      const local: SyncRecord = feedRecord('Title', 100, 'node-a');
      const tombstone: SyncRecord = feedRecord('', 200, 'node-b', true);
      const merged: SyncRecord = mergeRecord(local, tombstone);
      expect(merged.deleted).assertTrue();
      // 反向合并（较旧的存活记录）仍应保留墓碑。
      expect(mergeRecord(tombstone, local).deleted).assertTrue();
    });

    it('mergeRecord_tombstone_loses_when_older', 0, () => {
      const tombstone: SyncRecord = feedRecord('', 100, 'node-a', true);
      const revived: SyncRecord = feedRecord('Revived', 200, 'node-b');
      expect(mergeRecord(tombstone, revived).deleted).assertFalse();
    });

    // ---------- 文章状态：字段级合并 ----------

    it('mergeRecord_article_state_keeps_both_sides', 0, () => {
      // A 端在 100 标已读，B 端在 200 打星标：两边的改动都必须保留。
      const local: SyncRecord = stateRecord('1', '0', 100, 0, 'node-a');
      const remote: SyncRecord = stateRecord('0', '1', 0, 200, 'node-b');
      const merged: SyncRecord = mergeRecord(local, remote);
      const state: ArticleStatePayload = readState(merged);
      expect(state.read.value).assertEqual('1');
      expect(state.starred.value).assertEqual('1');
      expect(merged.updatedAt).assertEqual(200);
      expect(merged.deleted).assertFalse();
    });

    it('mergeRecord_article_state_newer_flag_wins_per_field', 0, () => {
      // 同一字段两端都改过：时间新的胜出（B 端取消已读晚于 A 端标已读）。
      const local: SyncRecord = stateRecord('1', '0', 100, 0, 'node-a');
      const remote: SyncRecord = stateRecord('0', '0', 300, 0, 'node-b');
      const merged: SyncRecord = mergeRecord(local, remote);
      expect(readState(merged).read.value).assertEqual('0');
    });

    it('mergeRecord_is_idempotent', 0, () => {
      // 合并结果再合并一次不应继续变化（重复同步不会来回改）。
      const local: SyncRecord = stateRecord('1', '0', 100, 0, 'node-a');
      const remote: SyncRecord = stateRecord('0', '1', 0, 200, 'node-b');
      const once: SyncRecord = mergeRecord(local, remote);
      const twice: SyncRecord = mergeRecord(once, remote);
      const threeTimes: SyncRecord = mergeRecord(twice, once);
      expect(isSameRecord(once, twice)).assertTrue();
      expect(isSameRecord(twice, threeTimes)).assertTrue();
    });

    // ---------- isSameRecord ----------

    it('isSameRecord_detects_changes', 0, () => {
      const base: SyncRecord = feedRecord('Title', 100, 'node-a');
      expect(isSameRecord(base, feedRecord('Title', 100, 'node-a'))).assertTrue();
      expect(isSameRecord(base, feedRecord('Other', 100, 'node-a'))).assertFalse();
      expect(isSameRecord(base, feedRecord('Title', 101, 'node-a'))).assertFalse();
      expect(isSameRecord(base, feedRecord('Title', 100, 'node-b'))).assertFalse();
    });
  });
}
