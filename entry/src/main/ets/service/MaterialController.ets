/*
 * MaterialController.ets — 沉浸光感材质（hdsMaterial）。
 *
 * 材质类型（MaterialType：自适应 / 沉浸式 / 无）与沉浸光感材质（MaterialLevel：四档）
 * 都来自 UIDesignKit，仅手机 / 平板、且仅 6.1.0(23)+。调 getSystemMaterialTypes() 前
 * 必须 try/catch —— 不支持时它会抛 801，而不是返回空数组。
 */

import { hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';
import { uiMaterial } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { MaterialKind, MaterialGrade } from '../common/constants/SettingsConstants';

export class MaterialController {
  private static cachedTypes: hdsMaterial.MaterialType[] | undefined = undefined;

  /** 设备支持的材质类型；不支持时返回空数组（并缓存，避免反复探测）。 */
  static supportedTypes(): hdsMaterial.MaterialType[] {
    const cached: hdsMaterial.MaterialType[] | undefined = MaterialController.cachedTypes;
    if (cached !== undefined) {
      return cached;
    }
    let types: hdsMaterial.MaterialType[] = [];
    try {
      types = hdsMaterial.getSystemMaterialTypes();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('hdsMaterial.getSystemMaterialTypes failed: ' + error.code.toString());
      types = [];
    }
    MaterialController.cachedTypes = types;
    return types;
  }

  /** 设备是否支持沉浸式材质。 */
  static immersiveSupported(): boolean {
    return MaterialController.supportedTypes().indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
  }

  /**
   * 应用级（全局）沉浸光感的开启状态。
   *
   * 由 module.json5 的 metadata `ohos.arkui.UIMaterial.state` 决定（仅 entry 模块生效）：
   * default / enable 开启，disable 关闭。运行时读取接口 getMaterialInfo() 自 26.0.0 起提供，
   * 低版本调用会抛异常，这里 try/catch 兜底为 false。
   */
  static globalEnabled(): boolean {
    try {
      const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
      return info.state === uiMaterial.MaterialState.ENABLE;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('uiMaterial.getMaterialInfo failed: ' + error.code.toString());
      return false;
    }
  }

  /** 语义 id -> MaterialType。 */
  static typeOf(id: string): hdsMaterial.MaterialType {
    if (id === MaterialKind.IMMERSIVE) {
      return hdsMaterial.MaterialType.IMMERSIVE;
    }
    if (id === MaterialKind.NONE) {
      return hdsMaterial.MaterialType.NONE;
    }
    return hdsMaterial.MaterialType.ADAPTIVE;
  }

  /** 语义 id -> MaterialLevel（四档）。 */
  static levelOf(id: string): hdsMaterial.MaterialLevel {
    if (id === MaterialGrade.EXQUISITE) {
      return hdsMaterial.MaterialLevel.EXQUISITE;
    }
    if (id === MaterialGrade.GENTLE) {
      return hdsMaterial.MaterialLevel.GENTLE;
    }
    if (id === MaterialGrade.SMOOTH) {
      return hdsMaterial.MaterialLevel.SMOOTH;
    }
    return hdsMaterial.MaterialLevel.ADAPTIVE;
  }

  /** 组装下发到 HdsTabs / HdsNavigation 的材质参数。总开关关掉时用 NONE。 */
  static params(typeId: string, levelId: string, immersiveOn: boolean): SystemMaterialParams {
    const result: SystemMaterialParams = {
      materialType: immersiveOn ? MaterialController.typeOf(typeId) : hdsMaterial.MaterialType.NONE,
      materialLevel: MaterialController.levelOf(levelId)
    };
    return result;
  }
}
