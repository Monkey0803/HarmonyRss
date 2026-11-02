import { describe, it, expect } from '@ohos/hypium';
import {
  parsePosition,
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
  });
}
