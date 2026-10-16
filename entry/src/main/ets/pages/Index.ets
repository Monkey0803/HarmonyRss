/*
 * Index.ets — 应用外壳（组装 View 与 ViewModel）。
 *
 * 结构：Stack（全局背景图）→ HdsNavigation（HDS 标题栏 + 路由）→ HdsTabs（HDS 悬浮页签）
 *       → HomeTabView / SettingsTabView /（图片领域时）ImageTabView；防窥遮罩盖在内容之上、页签栏之下。
 * 全局沉浸：窗口层设背景色兜底，根容器铺背景图，子页面背景透明。
 * 所有尺寸 / 颜色走 resources，逻辑常量走 common/constants。
 */

import { common } from '@kit.AbilityKit';
import {
  BlurStrategy,
  DynamicHideParams,
  HideMode,
  HdsTabs,
  HdsTabsController,
  HdsNavigation,
  HdsNavDestination,
  HdsNavigationTitle,
  HdsNavigationTitleMode,
  HdsNavDestinationTitleMode,
  HdsNavigationBackgroundStyle,
  HdsNavigationTitleBarStyle,
  ScrollEffectOptions,
  TitleBarContentOptions,
  TitleBarStyleOptions,
  HdsNavigationTitleBarOptions,
  HdsTabsFloatingStyle,
  SystemMaterialParams
} from '@kit.UIDesignKit';
import { appSettings } from '../model/AppSettings';
import { settingsViewModel } from '../viewmodel/SettingsViewModel';
import { MaterialController } from '../service/MaterialController';
import { antiPeep } from '../service/AntiPeep';
import { safeArea } from '../service/SafeAreaController';
import { backgroundImageService } from '../service/BackgroundImageService';
import { CommonConstants } from '../common/constants/CommonConstants';
import { TabIndex } from '../common/constants/NavigationConstants';
import { RouterConstants } from '../common/constants/RouterConstants';
import { BackgroundKind } from '../common/constants/SettingsConstants';
import { IMAGE_DOMAIN } from '../common/constants/DomainConstants';
import { HomeTabView } from '../views/HomeTabView';
import { SettingsTabView } from '../views/SettingsTabView';
import { ImageTabView } from '../views/ImageTabView';
import { PrivacyVeil } from '../views/PrivacyVeil';
import { ArticleDetailView } from '../views/ArticleDetailView';
import { SubscriptionsView } from '../views/SubscriptionsView';
import { EffectPreviewView } from '../views/EffectPreviewView';
import { feedViewModel } from '../viewmodel/FeedViewModel';

@Entry
@ComponentV2
struct Index {
  @Local currentTab: number = CommonConstants.DEFAULT_TAB_INDEX;
  @Local navPathStack: NavPathStack = new NavPathStack();
  private tabsController: HdsTabsController = new HdsTabsController();
  /** 每个页签独立的 Scroller：绑定给 HdsNavigation 做滚动联动，互不干扰。 */
  private homeScroller: Scroller = new Scroller();
  private settingsScroller: Scroller = new Scroller();

  /**
   * 各目的页自己的转场状态（自右滑入 + 淡入）。
   * customTransition 的代理对「进入的页」和「被覆盖的页」都会调用，共用一份状态会互相打架，
   * 所以每个目的页各持有一份 slide / alpha。
   */
  @Local articleSlideX: string = '0%';
  @Local articleAlpha: number = 1;
  @Local subsSlideX: string = '0%';
  @Local subsAlpha: number = 1;
  @Local effectSlideX: string = '0%';
  @Local effectAlpha: number = 1;

  aboutToAppear(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    settingsViewModel.init(context as common.Context);
    feedViewModel.init(context as common.Context);
  }

  aboutToDisappear(): void {
    antiPeep.stop();
  }

  /** 回到前台（或页面重新显示）时，按设置的自动刷新间隔决定是否抓取。 */
  onPageShow(): void {
    feedViewModel.maybeAutoRefresh();
  }

  private materialParams(): SystemMaterialParams {
    return MaterialController.params(appSettings.materialType, appSettings.materialLevel, appSettings.immersiveOn);
  }

  /** 只绑定当前页签的 Scroller，避免多页签互相干扰导致滚动模糊失效。 */
  private currentScroller(): Scroller {
    return this.currentTab === TabIndex.SETTINGS ? this.settingsScroller : this.homeScroller;
  }

  /**
   * 标题栏动态显隐：由设置页开关控制。
   * false（默认）—— 标题栏固定不动，内容从标题栏下方滚过；
   * true          —— 滚动内容时标题栏随之收起，反向滚动时恢复。
   */
  private dynamicHideParams(): DynamicHideParams {
    const params: DynamicHideParams = {
      hideTitleArea: appSettings.titleBarScrollsWithContent,
      hideStatusBar: false,
      hideBottomBuilder: false,
      mode: HideMode.SCROLL_UP_TO,
      hideOffset: CommonConstants.TITLE_HIDE_OFFSET_VP
    };
    return params;
  }

  /**
   * 根标题栏样式：**完全不画背景**（不用滚动动态效果、不做模糊、不加沉浸光感材质），
   * 起始态与滚动后背景都是全透明 —— 滚动时标题栏不会再出现一层背景。
   */
  private passThroughStyle(): TitleBarStyleOptions {
    const background: HdsNavigationBackgroundStyle = { backgroundColor: Color.Transparent };
    const titleBarStyle: HdsNavigationTitleBarStyle = { backgroundStyle: background };
    const scrollEffectOpts: ScrollEffectOptions = { enableScrollEffect: false };
    const style: TitleBarStyleOptions = {
      scrollEffectOpts: scrollEffectOpts,
      blurStrategy: BlurStrategy.DISABLE,
      originalStyle: titleBarStyle,
      scrollEffectStyle: titleBarStyle
    };
    return style;
  }

  /**
   * 标题栏配置（HdsNavigation / HdsNavDestination 共用）。
   *
   * avoidLayoutSafeArea: true —— 标题栏自身避让系统状态栏（标题文字不被状态栏 / 挖孔遮挡）。
   * enableComponentSafeArea: true —— 标题栏成为组件级安全区，**内容区由 HDS 自动排到标题栏下方**
   *   （不再由界面自己估算标题栏高度，避免首屏内容与标题栏重叠）。
   *   内容要「穿透」到标题栏下方，则靠可滚动容器上的 clip(false) + cachedCount 实现
   *   （见 views/HomeTabView.ets、views/SettingsTabView.ets）。
   */
  private titleOptions(mainTitle: ResourceStr, transparentBar: boolean): HdsNavigationTitleBarOptions {
    const title: HdsNavigationTitle = { mainTitle: mainTitle };
    const content: TitleBarContentOptions = { title: title };
    const style: TitleBarStyleOptions = transparentBar
      ? this.passThroughStyle()
      : { systemMaterialEffect: this.materialParams() };
    const options: HdsNavigationTitleBarOptions = {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: content,
      style: style
    };
    return options;
  }

  /**
   * 目的页转场：入场「自右滑入 + 淡入」，出场（pop）反向滑出并淡出；
   * 被覆盖 / 被重新露出的那一侧保持原位不动。
   *
   * 这里只是算出「起始态 / 终止态」，实际值由调用方通过 setSlide / setAlpha 写回
   * 该目的页自己的那一份状态（见上方 articleSlideX 等），系统再按 duration / curve 补间。
   */
  private slideFadeTransition(
    operation: NavigationOperation,
    isEnter: boolean,
    setSlide: (value: string) => void,
    setAlpha: (value: number) => void
  ): Array<NavDestinationTransition> | undefined {
    const enterPush: boolean = operation === NavigationOperation.PUSH && isEnter;
    const exitPop: boolean = operation === NavigationOperation.POP && !isEnter;
    const duration: number = exitPop ? CommonConstants.NAV_EXIT_DURATION_MS : CommonConstants.NAV_ENTER_DURATION_MS;

    // 起始态：入场从右侧屏外 + 全透明；其余情况从原位 + 不透明开始。
    setSlide(enterPush ? '100%' : '0%');
    setAlpha(enterPush ? 0 : 1);

    // 终止态：入场回到原位并淡入；出场滑出右侧并淡出；其余保持原位。
    const transition: NavDestinationTransition = {
      duration: duration,
      delay: 0,
      curve: Curve.Friction,
      event: () => {
        setSlide(exitPop ? '100%' : '0%');
        setAlpha(exitPop ? 0 : 1);
      }
    };
    return [transition];
  }

  private floatingStyle(): HdsTabsFloatingStyle {
    const style: HdsTabsFloatingStyle = {
      adaptToHandedness: appSettings.gripEnabled,
      // 悬浮页签栏默认距 HdsTabs 底部 0vp；全屏布局下会压住系统导航条，这里按避让高度上抬。
      barBottomMargin: safeArea.bottomInsetVp,
      systemMaterialEffect: this.materialParams()
    };
    return style;
  }

  /** 内置背景图资源（默认 / 极光 / 暮色）。 */
  private backgroundResource(): Resource {
    if (appSettings.backgroundKind === BackgroundKind.AURORA) {
      return $r('app.media.bg_aurora');
    }
    if (appSettings.backgroundKind === BackgroundKind.SUNSET) {
      return $r('app.media.bg_sunset');
    }
    return $r('app.media.app_background');
  }

  /** 当前是否应当绘制用户从相册选的自定义背景图。 */
  private hasCustomBackground(): boolean {
    return appSettings.backgroundKind === BackgroundKind.CUSTOM
      && appSettings.backgroundImagePath.length > 0
      && backgroundImageService.exists(appSettings.backgroundImagePath);
  }

  /**
   * 全局背景图层：铺满整个窗口（含状态栏 / 页签栏区域）实现沉浸式。
   * 「相册图片」用沙箱文件渲染；「无」不绘制，露出 Stack 的兜底色。
   */
  @Builder
  BackgroundLayer() {
    if (this.hasCustomBackground()) {
      Image(backgroundImageService.toImageSource(appSettings.backgroundImagePath))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .interpolation(ImageInterpolation.High)
    } else if (appSettings.backgroundKind !== BackgroundKind.NONE) {
      Image(this.backgroundResource())
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .interpolation(ImageInterpolation.High)
    }
  }

  @Builder
  barBuilder(icon: Resource, label: ResourceStr, active: boolean) {
    Column({ space: $r('app.float.space_xxs') }) {
      SymbolGlyph(icon)
        .fontSize($r('app.float.tab_icon_size'))
        .fontColor([active ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
      Text(label)
        .fontSize($r('app.float.tab_font_size'))
        .fontColor(active ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary'))
    }
    .width('100%')
    .height($r('app.float.tab_item_height'))
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  pageMap(name: string, pageInfos: Object) {
    if (name === RouterConstants.PAGE_ARTICLE) {
      HdsNavDestination() {
        ArticleDetailView()
      }
      .titleBar(this.titleOptions($r('app.string.article_title'), false))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_page_transparent'))
      .translate({ x: this.articleSlideX })
      .opacity(this.articleAlpha)
      .customTransition((operation: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
        return this.slideFadeTransition(operation, isEnter,
          (value: string) => {
            this.articleSlideX = value;
          },
          (value: number) => {
            this.articleAlpha = value;
          });
      })
    } else if (name === RouterConstants.PAGE_SUBSCRIPTIONS) {
      HdsNavDestination() {
        SubscriptionsView({ navPathStack: this.navPathStack })
      }
      .titleBar(this.titleOptions($r('app.string.subs_title'), false))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_page_transparent'))
      .translate({ x: this.subsSlideX })
      .opacity(this.subsAlpha)
      .customTransition((operation: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
        return this.slideFadeTransition(operation, isEnter,
          (value: string) => {
            this.subsSlideX = value;
          },
          (value: number) => {
            this.subsAlpha = value;
          });
      })
    } else if (name === RouterConstants.PAGE_EFFECT) {
      HdsNavDestination() {
        EffectPreviewView()
      }
      .titleBar(this.titleOptions($r('app.string.effect_title'), false))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_page_transparent'))
      .translate({ x: this.effectSlideX })
      .opacity(this.effectAlpha)
      .customTransition((operation: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
        return this.slideFadeTransition(operation, isEnter,
          (value: string) => {
            this.effectSlideX = value;
          },
          (value: number) => {
            this.effectAlpha = value;
          });
      })
    }
  }

  build() {
    Stack() {
      this.BackgroundLayer()

      HdsNavigation(this.navPathStack) {
        HdsTabs({ controller: this.tabsController }) {
          TabContent() {
            HomeTabView({ navPathStack: this.navPathStack, scroller: this.homeScroller })
          }
          .tabBar(this.barBuilder($r('sys.symbol.house'), $r('app.string.tab_home'), this.currentTab === TabIndex.HOME))

          TabContent() {
            SettingsTabView({ navPathStack: this.navPathStack, scroller: this.settingsScroller })
          }
          .tabBar(this.barBuilder($r('sys.symbol.gearshape'), $r('app.string.tab_settings'), this.currentTab === TabIndex.SETTINGS))

          if (IMAGE_DOMAIN) {
            TabContent() {
              ImageTabView()
            }
            .tabBar(this.barBuilder($r('sys.symbol.picture'), $r('app.string.tab_images'), this.currentTab === TabIndex.IMAGES))
          }
        }
        .barPosition(BarPosition.End)
        // barOverlap(true)：页签栏模糊悬浮并叠在内容之上（沉浸式外观，配合 barFloatingStyle + 材质）。
        // 代价是内容会延伸到页签栏下方，所以各页签的可滚动内容底部要用 tab_clearance 预留避让。
        // 若想要「内容与页签栏分离、天然避开」，改为 barOverlap(false) 并去掉底部预留即可。
        .barOverlap(true)
        .vertical(false)
        // 禁用左右滑动切页签：只能点页签栏切换，避免与内容区的横向手势冲突。
        .scrollable(false)
        .barFloatingStyle(this.floatingStyle())
        .onChange((index: number) => {
          this.currentTab = index;
        })
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.hm_page_transparent'))
      }
      .titleBar(this.titleOptions(this.currentTab === TabIndex.HOME
        ? $r('app.string.home_title')
        : $r('app.string.settings_title'), true))
      // 紧凑标题栏（默认 FREE 是大标题模式，标题上下留白很大）。
      .titleMode(HdsNavigationTitleMode.MINI)
      // 根页面没有上一级：MINI 模式下会默认显示返回键，这里隐藏。
      .hideBackButton(true)
      .mode(NavigationMode.Stack)
      .navDestination(this.pageMap)
      // 滚动联动：把当前页签的 Scroller 交给导航，供标题栏动态显隐（设置页开关）使用。
      .bindToScrollable([this.currentScroller()])
      // 标题栏是否随内容滚动（设置页开关）。
      .dynamicHideTitleBar(this.dynamicHideParams())
      .width('100%')
      .height('100%')

      if (antiPeep.peeking) {
        PrivacyVeil()
      }
    }
    .width('100%')
    .height('100%')
    // 背景图关闭时露出的兜底色（与窗口层 start_window_background 一致，含深浅色适配）。
    .backgroundColor($r('app.color.start_window_background'))
  }
}
