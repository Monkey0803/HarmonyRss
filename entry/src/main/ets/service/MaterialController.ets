/*
 * MaterialController.ets — 沉浸光感材质（hdsMaterial）。
 *
 * 材质类型（MaterialType：自适应 / 沉浸式 / 无）与沉浸光感材质（MaterialLevel：四档）
 * 都来自 UIDesignKit，仅手机 / 平板、且仅 6.1.0(23)+。调 getSystemMaterialTypes() 前
 * 必须 try/catch —— 不支持时它会抛 801，而不是返回空数组。
 */

import { hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';
import { uiMaterial } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
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

  /**
   * 设备是否具备「普通组件沉浸光感」（通用属性 systemMaterial + uiMaterial.ImmersiveMaterial，SDK 26.0.0 起）。
   *
   * 该能力新于工程声明的兼容版本 6.1.0(23)，所以只能运行时探测；探测用的 apiAvailable 也是 26.0.0 的接口，
   * 老版本设备上调用会失败，这里连同探测一起 catch —— 失败即视为不支持，调用方走实色兜底。
   */
  static componentMaterialSupported(immersiveOn: boolean): boolean {
    if (!immersiveOn) {
      return false;
    }
    try {
      if (!deviceInfo.apiAvailable('26.0.0')) {
        return false;
      }
      return uiMaterial.isImmersiveMaterialSupported();
    } catch (err) {
      return false;
    }
  }

  /**
   * 普通 ArkUI 组件（Row / Column 等自绘悬浮栏）的沉浸光感背板材质，走通用属性 systemMaterial。
   *
   * 与 HDS 轨道的 SystemMaterialParams 不是同一套参数：这里用 uiMaterial.ImmersiveStyle 描述厚度，
   * 官方建议悬浮工具栏用 ULTRA_THIN（最通透的一档）。colorInvert 让栏内文字 / 图标随背板自动反色，
   * 但要求这些颜色用 sys.color.font_* 这类特殊系统资源值，用业务色不会自适应。
   *
   * 设备不具备该能力（低算力 / 低版本 / 总开关关闭）或构造失败时返回 undefined，
   * 调用方退回实色背板，保证栏内文字始终可读。
   */
  static componentMaterial(immersiveOn: boolean): uiMaterial.Material | undefined {
    if (!MaterialController.componentMaterialSupported(immersiveOn)) {
      return undefined;
    }
    try {
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        colorInvert: true,
        interactive: true,
        lightEffect: { color: $r('sys.color.interactive_click') }
      });
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('uiMaterial.ImmersiveMaterial failed: ' + error.code.toString());
      return undefined;
    }
  }
}
