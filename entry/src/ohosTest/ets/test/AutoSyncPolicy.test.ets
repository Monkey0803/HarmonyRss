/*
 * AutoSyncPolicy.test.ets — 自动同步节流与重试策略单测。
 *
 * 覆盖：最小间隔（60s）内的重复触发被合并、从未同步时立刻可跑、
 * 失败重试绕过间隔、指数退避延迟与重试次数上限。
 */

import { describe, it, expect } from '@ohos/hypium';
import { AutoSyncPolicy } from '../../../main/ets/service/sync/AutoSyncPolicy';

const NOW: number = 1_700_000_000_000;

export default function autoSyncPolicyTest() {
  describe('AutoSyncPolicy', () => {
    it('isDue_runs_when_never_synced', 0, () => {
      expect(AutoSyncPolicy.isDue(0, NOW, true)).assertTrue();
      expect(AutoSyncPolicy.isDue(-1, NOW, true)).assertTrue();
    });

    it('isDue_throttles_within_gap', 0, () => {
      // 30 秒前刚同步过：冷启动 / 回前台 / 抓取完成连续触发也只跑一次。
      expect(AutoSyncPolicy.isDue(NOW - 30 * 1000, NOW, true)).assertFalse();
      // 边界之内 / 之外。
      expect(AutoSyncPolicy.isDue(NOW - AutoSyncPolicy.MIN_GAP_MS + 1, NOW, true)).assertFalse();
      expect(AutoSyncPolicy.isDue(NOW - AutoSyncPolicy.MIN_GAP_MS, NOW, true)).assertTrue();
    });

    it('isDue_retry_bypasses_gap', 0, () => {
      // 刚失败过（lastAttempt 很近）也要能立刻补试，否则退避定时器形同虚设。
      expect(AutoSyncPolicy.isDue(NOW - 1000, NOW, false)).assertTrue();
    });

    it('retry_delay_backs_off_exponentially', 0, () => {
      expect(AutoSyncPolicy.retryDelay(0)).assertEqual(30 * 1000);
      expect(AutoSyncPolicy.retryDelay(1)).assertEqual(60 * 1000);
      expect(AutoSyncPolicy.retryDelay(2)).assertEqual(120 * 1000);
      // 越界不溢出 / 不返回 0。
      expect(AutoSyncPolicy.retryDelay(-5)).assertEqual(30 * 1000);
      expect(AutoSyncPolicy.retryDelay(99) > 0).assertTrue();
    });

    it('retry_count_is_capped', 0, () => {
      expect(AutoSyncPolicy.canRetry(0)).assertTrue();
      expect(AutoSyncPolicy.canRetry(1)).assertTrue();
      expect(AutoSyncPolicy.canRetry(2)).assertTrue();
      // 第 4 次不再重试，交给下一次自动触发。
      expect(AutoSyncPolicy.canRetry(3)).assertFalse();
      expect(AutoSyncPolicy.canRetry(10)).assertFalse();
    });
  });
}
