/*
 * SheetDetents.test.ets — 半模态三挡高度生成（纯函数）。
 *
 * 规则：长内容首挡全高、向下可收；中等内容可展开 / 收起；
 * 固定 vp 的短面板保持原高度，只向上扩展。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  AppSheetDetents,
  SHEET_COMPACT_DETENT,
  sheetDetentsFor
} from '../../../main/ets/common/components/SheetDetents';

export default function sheetDetentsTest() {
  describe('SheetDetents', () => {
    it('large_initial_opens_full_then_collapses', 0, () => {
      const detents: AppSheetDetents = sheetDetentsFor(SheetSize.LARGE);
      expect(detents[0]).assertEqual(SheetSize.LARGE);
      expect(detents[1]).assertEqual(SheetSize.MEDIUM);
      expect(detents[2]).assertEqual(SHEET_COMPACT_DETENT);
    });

    it('medium_initial_can_expand_and_collapse', 0, () => {
      const detents: AppSheetDetents = sheetDetentsFor(SheetSize.MEDIUM);
      expect(detents[0]).assertEqual(SheetSize.MEDIUM);
      expect(detents[1]).assertEqual(SheetSize.LARGE);
      expect(detents[2]).assertEqual(SHEET_COMPACT_DETENT);
    });

    it('fixed_height_keeps_initial_and_expands_up', 0, () => {
      const detents: AppSheetDetents = sheetDetentsFor(360);
      expect(detents[0]).assertEqual(360);
      expect(detents[1]).assertEqual(SheetSize.MEDIUM);
      expect(detents[2]).assertEqual(SheetSize.LARGE);
    });
  });
}
