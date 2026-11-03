/*
 * SyncAvailability.test.ets — 云同步可观测性的纯函数单测。
 *
 * 覆盖三件事（都不触碰数据库 / 网络）：
 *   - 冲突概要的字段差异计算：只报「合并结果与远端不同」的键，脏 payload 直接空返回；
 *   - 墓碑过期判定：未推送的墓碑永不过期（否则删除动作会丢）；
 *   - 冲突概要的编解码：脏数据跳过，条数与字段数都有上限。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  SyncConflict,
  SyncKeys,
  WebPagePayload,
  changedPayloadFields,
  decodeWebPagePayload,
  encodeWebPagePayload
} from '../../../main/ets/model/Sync';
import { isTombstoneExpired, SyncLimits } from '../../../main/ets/service/sync/SyncStore';
import { decodeConflictDetails, encodeConflictDetails } from '../../../main/ets/service/SyncService';

const REMOTE: string = JSON.stringify({ read: '0', starred: '1', saved: '0', progress: '10' });
const MERGED: string = JSON.stringify({ read: '1', starred: '1', saved: '0', progress: '10' });

export default function syncAvailabilityTest() {
  describe('SyncAvailability', () => {
    it('changedFields_reports_only_diverged_keys', 0, () => {
      expect(changedPayloadFields(REMOTE, MERGED).join(',')).assertEqual('read');
      expect(changedPayloadFields(MERGED, MERGED).length).assertEqual(0);
      expect(changedPayloadFields(JSON.stringify({ a: '1', b: '2' }),
        JSON.stringify({ a: '9', b: '8' })).join(',')).assertEqual('a,b');
    });

    it('changedFields_tolerates_dirty_payload', 0, () => {
      expect(changedPayloadFields('', MERGED).length).assertEqual(0);
      expect(changedPayloadFields('not json', MERGED).length).assertEqual(0);
      expect(changedPayloadFields(REMOTE, '[]').length).assertEqual(0);
    });

    it('tombstone_expires_only_after_push_and_ttl', 0, () => {
      const now: number = 10 * 24 * 60 * 60 * 1000;
      // 刚删除、已推送：未到 30 天，保留。
      expect(isTombstoneExpired(true, false, now - 1000, now)).assertFalse();
      // 已推送且超过保留期：可清理。
      expect(isTombstoneExpired(true, false, now - SyncLimits.TOMBSTONE_TTL_MS - 1, now)).assertTrue();
      // 还没推送：永远不清理（删除动作还没到对端）。
      expect(isTombstoneExpired(true, true, 0, now)).assertFalse();
      // 非墓碑行不受影响。
      expect(isTombstoneExpired(false, false, 0, now)).assertFalse();
    });

    it('conflict_details_roundtrip_and_bounds', 0, () => {
      const items: SyncConflict[] = [
        new SyncConflict('articleState:a', 'articleState', ['read', 'starred']),
        new SyncConflict('feed:b', 'feed', [])
      ];
      const decoded: SyncConflict[] = decodeConflictDetails(encodeConflictDetails(items));
      expect(decoded.length).assertEqual(2);
      expect(decoded[0].key).assertEqual('articleState:a');
      expect(decoded[0].kind).assertEqual('articleState');
      expect(decoded[0].fields.join(',')).assertEqual('read,starred');
      expect(decoded[1].fields.length).assertEqual(0);
    });

    it('web_page_payload_roundtrip', 0, () => {
      const page: WebPagePayload = new WebPagePayload('https://a.com/x', 'Title', 'Source', 'sum', 123);
      const decoded: WebPagePayload | undefined = decodeWebPagePayload(encodeWebPagePayload(page));
      expect(decoded !== undefined).assertTrue();
      if (decoded !== undefined) {
        expect(decoded.url).assertEqual('https://a.com/x');
        expect(decoded.title).assertEqual('Title');
        expect(decoded.source).assertEqual('Source');
        expect(decoded.summary).assertEqual('sum');
        expect(decoded.savedAt).assertEqual(123);
      }
    });

    it('web_page_payload_tolerates_missing_fields', 0, () => {
      expect(decodeWebPagePayload('') === undefined).assertTrue();
      expect(decodeWebPagePayload('oops') === undefined).assertTrue();
      expect(decodeWebPagePayload('{}') === undefined).assertTrue();
      const minimal: WebPagePayload | undefined = decodeWebPagePayload('{"url":"https://a.com/x"}');
      expect(minimal !== undefined).assertTrue();
      if (minimal !== undefined) {
        expect(minimal.title).assertEqual('');
        expect(minimal.savedAt).assertEqual(0);
      }
    });

    it('web_page_key_is_stable_per_url', 0, () => {
      expect(SyncKeys.webPageKey('https://a.com/x')).assertEqual('webPage:https://a.com/x');
      expect(SyncKeys.webPageKey('https://a.com/x')).assertEqual(SyncKeys.webPageKey('https://a.com/x'));
    });

    it('conflict_details_ignores_dirty_json', 0, () => {
      expect(decodeConflictDetails('').length).assertEqual(0);
      expect(decodeConflictDetails('oops').length).assertEqual(0);
      expect(decodeConflictDetails('{}').length).assertEqual(0);
      expect(decodeConflictDetails('[{"key":"","kind":"feed"}]').length).assertEqual(0);
      // 字段数截断到上限。
      const many: SyncConflict[] = [new SyncConflict('k:1', 'articleState',
        ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'])];
      expect(decodeConflictDetails(encodeConflictDetails(many))[0].fields.length <= 6).assertTrue();
    });
  });
}
