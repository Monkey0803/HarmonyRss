/*
 * MaterialController.ets — 沉浸光感材质（hdsMaterial + uiMaterial）。
 *
 * 两条轨道，探针不能混用：
 *   - HDS 轨道（hdsMaterial）：HdsTabs / HdsNavigation 的 systemMaterialEffect，四档（含 ADAPTIVE）。
 *   - 组件级轨道（uiMaterial）：标题栏子组件 / 菜单 / 弹窗 / 半模态 / Toast 的 systemMaterial，三档只读。
 * 两者并非总是同时可用（只支持 HDS 轨道的设备上给弹层塞 uiMaterial 会让弹层渲染不出来）。
 *
 * 关键语义（来自官方「组件适配沉浸光感」）：
 *   systemMaterial(undefined) = 恢复默认。应用级 metadata 为 enable 时，菜单 / 弹窗 / Toggle 等
 *   默认就带材质，所以「关闭」必须显式传 uiMaterial.Material.empty，不能靠不传。
 */

import { hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';
import { promptAction, uiMaterial } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { MaterialKind, MaterialGrade } from '../common/constants/SettingsConstants';

/** 组件级沉浸材质的最低系统版本。 */
const GLASS_MIN_API: string = '26.0.0';

export class MaterialController {
  private static cachedTypes: hdsMaterial.MaterialType[] | undefined = undefined;
  private static cachedGlassSupported: boolean | undefined = undefined;
  private static cachedAppOn: boolean | undefined = undefined;
  private static levelRead: boolean = false;
  private static cachedLevel: uiMaterial.MaterialLevel | undefined = undefined;

  /** 设备支持的 HDS 材质类型；不支持时返回空数组（并缓存，避免反复探测）。 */
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

  /** 设备是否支持 HDS 沉浸式材质（HdsTabs / HdsNavigation 轨道）。 */
  static immersiveSupported(): boolean {
    return MaterialController.supportedTypes().indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
  }

  /**
   * 组件级沉浸材质是否可用：系统版本够 + 设备支持。
   *
   * 探针必须用 uiMaterial.isImmersiveMaterialSupported()（组件级轨道），不能用
   * hdsMaterial.getSystemMaterialTypes() —— 只支持 HDS 轨道的设备上给弹层塞材质会让弹层渲染不出来。
   */
  static glassSupported(): boolean {
    const cached: boolean | undefined = MaterialController.cachedGlassSupported;
    if (cached !== undefined) {
      return cached;
    }
    let supported: boolean = false;
    if (deviceInfo.apiAvailable(GLASS_MIN_API)) {
      try {
        supported = uiMaterial.isImmersiveMaterialSupported();
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        console.error('uiMaterial.isImmersiveMaterialSupported failed: ' + error.code.toString());
        supported = false;
      }
    }
    MaterialController.cachedGlassSupported = supported;
    return supported;
  }

  /**
   * 应用级开关是否允许材质。
   *
   * metadata `ohos.arkui.UIMaterial.state`：default / enable 允许，disable 一律禁止。
   * 注意不能写成 `state === ENABLE` —— default 模式下弹窗 / Toast 同样带材质。
   * 读不到（< 26.0.0）时按不允许处理（那时组件级材质本来也不可用）。
   */
  static appMaterialOn(): boolean {
    const cached: boolean | undefined = MaterialController.cachedAppOn;
    if (cached !== undefined) {
      return cached;
    }
    let on: boolean = false;
    try {
      const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
      on = info.state !== uiMaterial.MaterialState.DISABLE;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('uiMaterial.getMaterialInfo failed: ' + error.code.toString());
      on = false;
    }
    MaterialController.cachedAppOn = on;
    return on;
  }

  /**
   * 设备算力档（EXQUISITE / GENTLE / SMOOTH）；取不到时为 undefined。
   * 低算力设备上强行下发高档材质会卡顿发热，params() 据此钳到 ADAPTIVE。
   */
  static globalLevel(): uiMaterial.MaterialLevel | undefined {
    if (MaterialController.levelRead) {
      return MaterialController.cachedLevel;
    }
    MaterialController.levelRead = true;
    if (!deviceInfo.apiAvailable(GLASS_MIN_API)) {
      return undefined;
    }
    try {
      MaterialController.cachedLevel = uiMaterial.getGlobalMaterialLevel();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('uiMaterial.getGlobalMaterialLevel failed: ' + error.code.toString());
      MaterialController.cachedLevel = undefined;
    }
    return MaterialController.cachedLevel;
  }

  /** 组件级材质是否真的会渲染：应用内总开关开 + 设备支持 + 应用级未禁用。 */
  static materialRenders(immersiveOn: boolean): boolean {
    return immersiveOn && MaterialController.glassSupported() && MaterialController.appMaterialOn();
  }

  /** HDS 轨道（HdsTabs / HdsNavigation）是否真的会渲染。 */
  static immersiveActive(immersiveOn: boolean): boolean {
    return immersiveOn && MaterialController.immersiveSupported() && MaterialController.appMaterialOn();
  }

  /**
   * 组件级材质的统一出口：
   *   - 设备 / 应用级已无材质可言 → undefined（不传，组件走自身兜底）；
   *   - 用户关掉开关 → uiMaterial.Material.empty（显式关闭；传 undefined 只会「恢复默认」）；
   *   - 开启 → 交给 build() 构造具体材质。
   */
  private static materialOrOff(immersiveOn: boolean, build: () => uiMaterial.Material): uiMaterial.Material | undefined {
    if (!MaterialController.glassSupported() || !MaterialController.appMaterialOn()) {
      return undefined;
    }
    if (!immersiveOn) {
      return uiMaterial.Material.empty;
    }
    try {
      return build();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('uiMaterial.ImmersiveMaterial failed: ' + error.code.toString());
      return undefined;
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

  /** 低算力设备上把用户选的高档钳回 ADAPTIVE（官方建议：不要强行下发精致 / 均衡）。 */
  static clampLevel(picked: hdsMaterial.MaterialLevel): hdsMaterial.MaterialLevel {
    return MaterialController.clampLevelFor(picked,
      MaterialController.globalLevel() === uiMaterial.MaterialLevel.SMOOTH);
  }

  /** 纯函数（ohosTest 覆盖）：低算力设备上把高档钳回 ADAPTIVE。 */
  static clampLevelFor(picked: hdsMaterial.MaterialLevel, lowPower: boolean): hdsMaterial.MaterialLevel {
    return lowPower ? hdsMaterial.MaterialLevel.ADAPTIVE : picked;
  }

  /** 设备算力档 -> 语义 id（设置页展示用；取不到返回空串，界面据此不显示该项）。 */
  static globalLevelId(): string {
    const level: uiMaterial.MaterialLevel | undefined = MaterialController.globalLevel();
    if (level === uiMaterial.MaterialLevel.EXQUISITE) {
      return MaterialGrade.EXQUISITE;
    }
    if (level === uiMaterial.MaterialLevel.GENTLE) {
      return MaterialGrade.GENTLE;
    }
    if (level === uiMaterial.MaterialLevel.SMOOTH) {
      return MaterialGrade.SMOOTH;
    }
    return '';
  }

  /**
   * 弹层（Menu / Sheet / AlertDialog / Toast）用的组件级沉浸光感材质。
   *
   * 弹层属于「全页面生效」场景，但走 ArkUI 组件级轨道：需要 targetAPIVersion ≥ 26.0.0
   * 且设备真正支持组件级沉浸材质，并且要在弹层的 options 里显式给出 systemMaterial
   * （官方最佳实践「菜单栏适配沉浸光感」的做法）。
   */
  static overlayMaterial(immersiveOn: boolean): uiMaterial.Material | undefined {
    return MaterialController.materialOrOff(immersiveOn, (): uiMaterial.Material => {
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THICK,
        interactive: true,
        lightEffect: { color: undefined }
      });
    });
  }

  /**
   * 内容区交互控件（分段按钮 / 标题栏胶囊）用的组件级沉浸光感材质。
   *
   * 控件尺寸小、面积薄，用 THIN，并开启按压形变与点光源，替代默认按压态。
   */
  static controlMaterial(immersiveOn: boolean): uiMaterial.Material | undefined {
    return MaterialController.materialOrOff(immersiveOn, (): uiMaterial.Material => {
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        interactive: true,
        lightEffect: { color: undefined }
      });
    });
  }

  /**
   * 分段按钮（SegmentButtonV2）背景板用的组件级沉浸光感材质。
   *
   * 按官方「设置背景板材质」范例取 ULTRA_THIN：按钮面积小、需要透出底下的标题栏内容；
   * colorInvert 让文字随材质下方背景自动反色（配合 itemFontColor 传系统资源色），
   * interactive 提供按压形变，lightEffect 用系统交互色做流光。
   *
   * 材质等级越高越厚（精致 → THIN，其余 → ULTRA_THIN —— colorInvert 只在这两档生效）。
   * 用户把材质类型选成「无」时返回 empty：应用级 enable 下不显式关闭的话，
   * 分段按钮会继续吃系统默认材质。
   */
  static segmentMaterial(immersiveOn: boolean, typeId: string, levelId: string): uiMaterial.Material | undefined {
    return MaterialController.materialOrOff(MaterialController.segmentMaterialWanted(immersiveOn, typeId),
      (): uiMaterial.Material => {
        return new uiMaterial.ImmersiveMaterial({
          style: levelId === MaterialGrade.EXQUISITE
            ? uiMaterial.ImmersiveStyle.THIN
            : uiMaterial.ImmersiveStyle.ULTRA_THIN,
          colorInvert: true,
          interactive: true,
          lightEffect: { color: $r('sys.color.interactive_click') }
        });
      });
  }

  /** 设置层面是否要求分段按钮有材质（总开关开 + 类型不是「无」）。 */
  static segmentMaterialWanted(immersiveOn: boolean, typeId: string): boolean {
    return immersiveOn && typeId !== MaterialKind.NONE;
  }

  /**
   * 标题栏悬浮胶囊 / 筛选胶囊用的材质（组件级轨道，返回非空类型）。
   *
   * 调用方用 materialRenders() 决定要不要走材质分支；这里在不可渲染时返回 empty，
   * 避免 ArkTS 里为了收窄类型写类型断言。
   */
  static titleMaterial(immersiveOn: boolean): uiMaterial.Material {
    const material: uiMaterial.Material | undefined = MaterialController.controlMaterial(immersiveOn);
    if (material !== undefined) {
      return material;
    }
    return uiMaterial.Material.empty;
  }

  /** 上下文菜单（bindMenu）注入沉浸光感；不支持时原样返回。 */
  static menuOptions(options: ContextMenuOptions, immersiveOn: boolean): ContextMenuOptions {
    const material: uiMaterial.Material | undefined = MaterialController.overlayMaterial(immersiveOn);
    if (material !== undefined) {
      options.systemMaterial = material;
    }
    return options;
  }

  /** 半模态面板（bindSheet）注入沉浸光感；不支持时原样返回。 */
  static sheetOptions(options: SheetOptions, immersiveOn: boolean): SheetOptions {
    const material: uiMaterial.Material | undefined = MaterialController.overlayMaterial(immersiveOn);
    if (material !== undefined) {
      options.systemMaterial = material;
    }
    return options;
  }

  /** 对话框（showAlertDialog）注入沉浸光感；不支持时原样返回。 */
  static dialogParams<T extends AlertDialogParam>(params: T, immersiveOn: boolean): T {
    const material: uiMaterial.Material | undefined = MaterialController.overlayMaterial(immersiveOn);
    if (material !== undefined) {
      params.systemMaterial = material;
    }
    return params;
  }

  /** Toast 注入沉浸光感；不支持时原样返回。 */
  static toastOptions(options: promptAction.ShowToastOptions, immersiveOn: boolean): promptAction.ShowToastOptions {
    const material: uiMaterial.Material | undefined = MaterialController.overlayMaterial(immersiveOn);
    if (material !== undefined) {
      options.systemMaterial = material;
    }
    return options;
  }

  /** 组装下发到 HdsTabs / HdsNavigation 的材质参数。总开关关掉时用 NONE，低算力设备钳到 ADAPTIVE。 */
  static params(typeId: string, levelId: string, immersiveOn: boolean): SystemMaterialParams {
    const result: SystemMaterialParams = {
      materialType: immersiveOn ? MaterialController.typeOf(typeId) : hdsMaterial.MaterialType.NONE,
      materialLevel: MaterialController.clampLevel(MaterialController.levelOf(levelId))
    };
    return result;
  }
}
