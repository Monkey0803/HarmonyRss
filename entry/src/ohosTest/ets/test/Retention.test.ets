/*
 * Retention.test.ets — 保留清理保护条件单测。
 *
 * 覆盖：收藏 / 稍后读 / 有高亮 / 当前打开文章 永不清理；按天数判定；「仅保留未读」判定。
 */

import { describe, it, expect } from '@ohos/hypium';
import { RetentionPolicy } from '../../../main/ets/model/Search';

export default function retentionTest() {
  describe('RetentionPolicy', () => {
    it('protects_starred', 0, () => {
      expect(RetentionPolicy.isProtected(true, false, 0, '', 'a')).assertTrue();
    });

    it('protects_saved', 0, () => {
      expect(RetentionPolicy.isProtected(false, true, 0, '', 'a')).assertTrue();
    });

    it('protects_highlighted', 0, () => {
      expect(RetentionPolicy.isProtected(false, false, 2, '', 'a')).assertTrue();
      expect(RetentionPolicy.isProtected(false, false, 0, '', 'a')).assertFalse();
    });

    it('protects_current_article', 0, () => {
      expect(RetentionPolicy.isProtected(false, false, 0, 'a', 'a')).assertTrue();
      expect(RetentionPolicy.isProtected(false, false, 0, 'a', 'b')).assertFalse();
      // 没有当前文章时不应误判为空 id 相等。
      expect(RetentionPolicy.isProtected(false, false, 0, '', '')).assertFalse();
    });

    it('older_than_days', 0, () => {
      const now: number = 1_800_000_000_000;
      const day: number = RetentionPolicy.DAY_MS;
      expect(RetentionPolicy.isOlderThan(now - 31 * day, 30, now)).assertTrue();
      expect(RetentionPolicy.isOlderThan(now - 29 * day, 30, now)).assertFalse();
      // 90 天档位不清理 31 天前的。
      expect(RetentionPolicy.isOlderThan(now - 31 * day, 90, now)).assertFalse();
    });

    it('permanent_never_cleans', 0, () => {
      const now: number = 1_800_000_000_000;
      expect(RetentionPolicy.isOlderThan(now - 400 * RetentionPolicy.DAY_MS, 0, now)).assertFalse();
      expect(RetentionPolicy.isOlderThan(now - 400 * RetentionPolicy.DAY_MS, -1, now)).assertFalse();
    });

    it('missing_published_at_is_safe', 0, () => {
      const now: number = 1_800_000_000_000;
      expect(RetentionPolicy.isOlderThan(0, 30, now)).assertFalse();
    });

    it('unread_mode_candidate', 0, () => {
      expect(RetentionPolicy.isUnreadModeCandidate(true)).assertTrue();
      expect(RetentionPolicy.isUnreadModeCandidate(false)).assertFalse();
    });
  });
}
