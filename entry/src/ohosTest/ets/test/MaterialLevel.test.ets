/*
 * MaterialLevel.test.ets — 材质等级钳制与语义 id 映射（纯函数）。
 *
 * 低算力设备（uiMaterial SMOOTH）上强行下发「精致 / 均衡」会卡顿发热，
 * 官方建议一律退回 ADAPTIVE，由系统按能力自己挑档。
 */

import { describe, it, expect } from '@ohos/hypium';
import { hdsMaterial } from '@kit.UIDesignKit';
import { MaterialController } from '../../../main/ets/service/MaterialController';
import { MaterialGrade, MaterialKind } from '../../../main/ets/common/constants/SettingsConstants';

export default function materialLevelTest() {
  describe('MaterialLevel', () => {
    it('clamps_high_grade_on_low_power', 0, () => {
      expect(MaterialController.clampLevelFor(hdsMaterial.MaterialLevel.EXQUISITE, true))
        .assertEqual(hdsMaterial.MaterialLevel.ADAPTIVE);
      expect(MaterialController.clampLevelFor(hdsMaterial.MaterialLevel.GENTLE, true))
        .assertEqual(hdsMaterial.MaterialLevel.ADAPTIVE);
    });

    it('keeps_picked_level_on_capable_device', 0, () => {
      expect(MaterialController.clampLevelFor(hdsMaterial.MaterialLevel.EXQUISITE, false))
        .assertEqual(hdsMaterial.MaterialLevel.EXQUISITE);
      expect(MaterialController.clampLevelFor(hdsMaterial.MaterialLevel.GENTLE, false))
        .assertEqual(hdsMaterial.MaterialLevel.GENTLE);
      expect(MaterialController.clampLevelFor(hdsMaterial.MaterialLevel.SMOOTH, false))
        .assertEqual(hdsMaterial.MaterialLevel.SMOOTH);
    });

    it('maps_semantic_level_ids', 0, () => {
      expect(MaterialController.levelOf(MaterialGrade.EXQUISITE)).assertEqual(hdsMaterial.MaterialLevel.EXQUISITE);
      expect(MaterialController.levelOf(MaterialGrade.GENTLE)).assertEqual(hdsMaterial.MaterialLevel.GENTLE);
      expect(MaterialController.levelOf(MaterialGrade.SMOOTH)).assertEqual(hdsMaterial.MaterialLevel.SMOOTH);
      expect(MaterialController.levelOf(MaterialGrade.ADAPTIVE)).assertEqual(hdsMaterial.MaterialLevel.ADAPTIVE);
    });

    it('maps_semantic_type_ids', 0, () => {
      expect(MaterialController.typeOf(MaterialKind.IMMERSIVE)).assertEqual(hdsMaterial.MaterialType.IMMERSIVE);
      expect(MaterialController.typeOf(MaterialKind.NONE)).assertEqual(hdsMaterial.MaterialType.NONE);
      expect(MaterialController.typeOf('unknown')).assertEqual(hdsMaterial.MaterialType.ADAPTIVE);
    });
  });
}
