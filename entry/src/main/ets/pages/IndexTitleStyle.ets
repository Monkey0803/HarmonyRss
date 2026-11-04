/* Shared title-bar material and scroll behavior for the app shell and destinations. */
import { DynamicHideParams, HideMode, HdsNavigationTitleBarStyle,
  HdsNavigationTitle, HdsNavigationTitleBarOptions, ScrollEffectOptions,
  ScrollEffectType, SystemMaterialParams, TitleBarContentOptions,
  TitleBarStyleOptions } from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { appSettings } from '../model/AppSettings';
import { MaterialController } from '../service/MaterialController';
import { CommonConstants } from '../common/constants/CommonConstants';

export function indexMaterialParams(): SystemMaterialParams {
    return MaterialController.params(appSettings.materialType, appSettings.materialLevel, appSettings.immersiveOn);
  }

  /**
   * 标题栏 / 状态栏动态显隐：各由一个设置页开关控制（沉浸光感最佳实践建议都开，这里交给用户）。
   * 标题栏：false（默认）固定不动、内容从标题栏下方滚过；true 滚动时收起。
   * 状态栏：false（默认）常驻；true 滚动内容时一并收起。
   */
export function indexDynamicHideParams(): DynamicHideParams {
    const params: DynamicHideParams = {
      hideTitleArea: appSettings.titleBarScrollsWithContent,
      hideStatusBar: appSettings.statusBarScrollsWithContent,
      hideBottomBuilder: false,
      mode: HideMode.SCROLL_UP_TO,
      hideOffset: CommonConstants.TITLE_HIDE_OFFSET_VP
    };
    return params;
  }

  /**
   * 标题栏背板底色。
   *
   * 沉浸光感的视觉层级在 backgroundColor 之下：材质会渲染时底色必须留透明，否则会盖住材质
   * （见沉浸光感 FAQ「背景色或背景模糊遮挡材质效果」）；材质不可用（总开关关闭 / 设备不支持）时
   * 才补一层系统灰底，保证内容从标题栏下方穿过时标题仍看得清。
   */
function titleBackdropColor(): ResourceColor {
    return MaterialController.immersiveActive(appSettings.immersiveOn)
      ? Color.Transparent
      : $r('sys.color.comp_background_gray');
  }

  /**
   * 标题栏样式（全 App 统一）：沉浸光感材质（hdsMaterial）+ 跟手线性渐变。
   *
   * - 静止态（originalStyle）：背景全透明，标题栏与页面融为一体。
   * - 滚动后（scrollEffectStyle）：露出沉浸光感材质背板（底色见 titleBackdropColor）。
   * - enableScrollEffect: true + GRADIENT_BLUR：标题栏样式随内容区滚动偏移**线性跟手**过渡
   *   （0 → TITLE_MATERIAL_FADE_VP），与底部悬浮页签栏同源材质。
   *
   * 需要各页用 bindToScrollable 绑定其可滚动容器，标题栏才能拿到滚动偏移。
   */
export function indexMaterialTitleStyle(): TitleBarStyleOptions {
    const backdrop: ResourceColor = titleBackdropColor();
    const original: HdsNavigationTitleBarStyle = {
      backgroundStyle: { backgroundColor: Color.Transparent }
    };
    const scrolled: HdsNavigationTitleBarStyle = {
      backgroundStyle: { backgroundColor: backdrop }
    };
    const scrollEffectOpts: ScrollEffectOptions = {
      enableScrollEffect: true,
      // 用 GRADIENT_BLUR（半透明 → 模糊）而不是 IMMERSIVE_GRADIENT_BLUR：
      // 后者在浅色主题下会让系统把标题文字与状态栏图标切成白色（它假定深色底），
      // 本 App 是浅色为主的阅读器，实测白字压在浅色壁纸上看不清，故保留更克制的变体。
      scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
      blurEffectiveStartOffset: LengthMetrics.vp(0),
      blurEffectiveEndOffset: LengthMetrics.vp(CommonConstants.TITLE_MATERIAL_FADE_VP)
    };
    const style: TitleBarStyleOptions = {
      scrollEffectOpts: scrollEffectOpts,
      originalStyle: original,
      scrollEffectStyle: scrolled,
      systemMaterialEffect: indexMaterialParams()
    };
    return style;
  }

  /**
   * 标题栏配置（HdsNavigation / HdsNavDestination 共用，全 App 一套样式）。
   *
   * avoidLayoutSafeArea: true —— 标题栏自身避让系统状态栏（标题文字不被状态栏 / 挖孔遮挡）。
   * enableComponentSafeArea: false —— 标题栏作为「浮层」叠在内容之上，内容区铺满可滚动区域，
   *   滚动时内容穿过标题栏下方被材质衬托（各页在内容顶部补一个「状态栏 + 标题栏」高的占位，
   *   保证首屏不被遮挡）。
   */
export function indexTitleOptions(mainTitle: ResourceStr): HdsNavigationTitleBarOptions {
    const title: HdsNavigationTitle = { mainTitle: mainTitle };
    const content: TitleBarContentOptions = { title: title };
    const options: HdsNavigationTitleBarOptions = {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false,
      content: content,
      style: indexMaterialTitleStyle()
    };
    return options;
  }
