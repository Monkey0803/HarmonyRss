import { describe, it, expect } from '@ohos/hypium';
import { ReaderPosition } from '../../../main/ets/service/ReaderProgress';
import { ReaderProgressQueue } from '../../../main/ets/service/ReaderProgressQueue';

export default function readerProgressQueueTest(): void {
  describe('ReaderProgressQueue', () => {
    it('keeps_modes_separate_and_flushes_latest_position_only', 0, () => {
      const saved: string[] = [];
      const queue: ReaderProgressQueue = new ReaderProgressQueue((id: string, position: ReaderPosition): void => {
        saved.push(id + ':' + position.y);
      }, (): boolean => false);
      queue.queue('a', 'reader', new ReaderPosition(10, 0.1));
      queue.queue('a', 'web', new ReaderPosition(20, 0.2));
      expect(queue.positionOf('a', 'reader')?.y).assertEqual(10);
      expect(queue.positionOf('a', 'web')?.y).assertEqual(20);
      queue.flush();
      expect(saved.join(',')).assertEqual('a:20');
      queue.clearArticle('a', 'reader', 'web');
      expect(queue.positionOf('a', 'reader')).assertUndefined();
      expect(queue.positionOf('a', 'web')).assertUndefined();
    });

    it('does_not_save_finished_or_cleared_positions', 0, () => {
      let saved: number = 0;
      let finished: boolean = false;
      const queue: ReaderProgressQueue = new ReaderProgressQueue((): void => {
        saved += 1;
      }, (): boolean => finished);
      queue.queue('a', 'reader', new ReaderPosition(10, 0.1));
      finished = true;
      queue.flush();
      queue.queue('a', 'reader', new ReaderPosition(20, 0.2));
      queue.clear();
      queue.flush();
      expect(saved).assertEqual(0);
    });
  });
}
