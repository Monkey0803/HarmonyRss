/*
 * NotifyQueue.test.ets — 免打扰待通知队列的编解码与归一化单测。
 *
 * 覆盖：
 *   - 去重：同一文章重复入队只保留一条（后来的覆盖先前的，视为更新）；
 *   - 限长：超过 NOTIFY_QUEUE_MAX 时丢弃最旧的，保留最新的一批；
 *   - 脏数据：非法 JSON 返回空数组、空 articleId 丢弃、非法 at 归零；
 *   - 编解码往返：encode → decode 保持条数与顺序。
 *
 * 只测纯函数，不打开偏好库。
 */

import { describe, it, expect } from '@ohos/hypium';
import { NotifyQueueItem } from '../../../main/ets/model/Notify';
import { CommonConstants } from '../../../main/ets/common/constants/CommonConstants';
import { decodeQueue, encodeQueue, normalizeQueue } from '../../../main/ets/service/NotifyStore';

/** 构造一条队列项。 */
function item(articleId: string, feedId: string, at: number): NotifyQueueItem {
  return new NotifyQueueItem(articleId, feedId, at);
}

export default function notifyQueueTest() {
  describe('NotifyQueue', () => {
    it('normalizeQueue_dedupes_by_article', 0, () => {
      const result: NotifyQueueItem[] = normalizeQueue([
        item('a1', 'f1', 100),
        item('a2', 'f1', 200),
        item('a1', 'f2', 300)
      ]);
      expect(result.length).assertEqual(2);
      // 后入队的 a1 覆盖先前的：位置保持「最新一次入队」的顺序。
      expect(result[0].articleId).assertEqual('a2');
      expect(result[1].articleId).assertEqual('a1');
      expect(result[1].feedId).assertEqual('f2');
      expect(result[1].at).assertEqual(300);
    });

    it('normalizeQueue_drops_empty_ids_and_invalid_at', 0, () => {
      const result: NotifyQueueItem[] = normalizeQueue([
        item('', 'f1', 100),
        item('a1', 'f1', Number.NaN)
      ]);
      expect(result.length).assertEqual(1);
      expect(result[0].articleId).assertEqual('a1');
      expect(result[0].at).assertEqual(0);
    });

    it('normalizeQueue_caps_to_limit_keeping_newest', 0, () => {
      const input: NotifyQueueItem[] = [];
      for (let i = 0; i < CommonConstants.NOTIFY_QUEUE_MAX + 10; i += 1) {
        input.push(item('a' + i.toString(), 'f1', i));
      }
      const result: NotifyQueueItem[] = normalizeQueue(input);
      expect(result.length).assertEqual(CommonConstants.NOTIFY_QUEUE_MAX);
      // 丢弃最旧的 10 条，剩下的仍按入队顺序（从 a10 开始）。
      expect(result[0].articleId).assertEqual('a10');
      expect(result[result.length - 1].articleId)
        .assertEqual('a' + (CommonConstants.NOTIFY_QUEUE_MAX + 9).toString());
    });

    it('decodeQueue_handles_bad_input', 0, () => {
      expect(decodeQueue('').length).assertEqual(0);
      expect(decodeQueue('not-json').length).assertEqual(0);
      expect(decodeQueue('{}').length).assertEqual(0);
      // 非法项被丢弃，合法项保留。
      const result: NotifyQueueItem[] = decodeQueue(
        '[{"articleId":"a1","feedId":"f1","at":10},{"articleId":"","feedId":"f2","at":20}]');
      expect(result.length).assertEqual(1);
      expect(result[0].articleId).assertEqual('a1');
    });

    it('encode_decode_round_trip', 0, () => {
      const source: NotifyQueueItem[] = [
        item('a1', 'f1', 100),
        item('a2', 'f2', 200)
      ];
      const decoded: NotifyQueueItem[] = decodeQueue(encodeQueue(source));
      expect(decoded.length).assertEqual(2);
      expect(decoded[0].articleId).assertEqual('a1');
      expect(decoded[0].feedId).assertEqual('f1');
      expect(decoded[0].at).assertEqual(100);
      expect(decoded[1].articleId).assertEqual('a2');
      expect(decoded[1].at).assertEqual(200);
    });
  });
}
