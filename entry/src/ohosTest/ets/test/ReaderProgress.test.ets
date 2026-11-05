import { describe, it, expect } from '@ohos/hypium';
import {
  parsePosition,
  positionFromMetrics,
  progressObserverScript,
  readPositionScript,
  restorePositionScript
} from '../../../main/ets/service/ReaderProgress';

export default function readerProgressTest() {
  describe('ReaderProgress', () => {
    it('keeps_scroll_ratio_for_changed_layout', 0, () => {
      const position = parsePosition('"600|3200|800"');
      expect(position.y).assertEqual(600);
      expect(position.ratio).assertEqual(0.25);
      expect(parsePosition('broken').ratio).assertEqual(0);
    });

    it('reads_scroll_coordinate_with_document_height', 0, () => {
      const script: string = readPositionScript();
      expect(script.includes('window.scrollY')).assertTrue();
      expect(script.includes('scrollHeight')).assertTrue();
    });

    it('lets_user_scroll_cancel_pending_restore', 0, () => {
      const script: string = restorePositionScript(0.5, 600);
      expect(script.includes('window.__hrRestoreCancel')).assertTrue();
      expect(script.includes('addEventListener("touchstart",done')).assertTrue();
      expect(script.includes('n>=25')).assertTrue();
    });

    it('computes_position_from_scroll_metrics', 0, () => {
      const position = positionFromMetrics(600, 3200, 800);
      expect(position.y).assertEqual(600);
      expect(position.ratio).assertEqual(0.25);
      // 负数 / 文档比视口短 / 非法值都收敛到 0，避免进度条倒跳。
      expect(positionFromMetrics(-1, 3200, 800).y).assertEqual(0);
      expect(positionFromMetrics(10, 700, 800).ratio).assertEqual(0);
      expect(positionFromMetrics(Number.NaN, 3200, 800).ratio).assertEqual(0);
    });

    it('reports_scroll_position_from_document', 0, () => {
      const script: string = progressObserverScript();
      // 幂等绑定：同一文档重复注入只挂一次监听。
      expect(script.includes('__hrProgressBound')).assertTrue();
      expect(script.includes('hrProgress.onScroll')).assertTrue();
      expect(script.includes('addEventListener("scroll"')).assertTrue();
    });
  });
}
