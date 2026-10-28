/*
 * CloudRelay.test.ets — 云端同步后端的游标纯函数单测。
 *
 * 不触碰数据库：只验证「游标是毫秒时间戳字符串」的解析与比较，
 * 以及非法输入（空串 / 非数字）退化为 0，避免脏游标把增量同步卡死。
 */

import { describe, it, expect } from '@ohos/hypium';
import { CloudRelayBackend, numericCursor } from '../../../main/ets/service/sync/CloudRelayBackend';
import { cloudStore } from '../../../main/ets/service/sync/CloudStore';

export default function cloudRelayTest(): void {
  describe('CloudRelay', () => {
    it('numericCursor_parses_timestamps', 0, () => {
      expect(numericCursor('1700000000000')).assertEqual(1700000000000);
      expect(numericCursor('1')).assertEqual(1);
    });

    it('numericCursor_rejects_dirty_values', 0, () => {
      expect(numericCursor('')).assertEqual(0);
      expect(numericCursor('abc')).assertEqual(0);
      expect(numericCursor('-5')).assertEqual(0);
      expect(numericCursor('Infinity')).assertEqual(0);
    });

    it('betterCursor_keeps_newer', 0, () => {
      const backend: CloudRelayBackend = new CloudRelayBackend(cloudStore);
      expect(backend.betterCursor('100', '200')).assertEqual('200');
      expect(backend.betterCursor('200', '100')).assertEqual('200');
      // 非法候选值不推进游标。
      expect(backend.betterCursor('200', '')).assertEqual('200');
      expect(backend.betterCursor('', '0')).assertEqual('');
    });
  });
}
