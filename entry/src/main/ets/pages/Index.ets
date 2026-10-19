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
  DynamicHideParams,
  HideMode,
  HdsTabs,
  HdsTabsController,
  HdsNavigation,
  HdsNavDestination,
  HdsNavigationTitle,
  HdsNavigationTitleMode,
  HdsNavDestinationTitleMode,
  HdsNavigationTitleBarStyle,
  ScrollEffectOptions,
  ScrollEffectType,
  TitleBarContentOptions,
  TitleBarStyleOptions,
  HdsNavigationTitleBarOptions,
  HdsTabsFloatingStyle,
  SystemMaterialParams
} from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { appSettings } from '../model/AppSettings';
import { settingsViewModel } from '../viewmodel/SettingsViewModel';
import { MaterialController } from '../service/MaterialController';
import { antiPeep } from '../service/AntiPeep';
import { gripSensor } from '../service/GripSensor';
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
import { FeedArticlesView } from '../views/FeedArticlesView';
import { EffectPreviewView } from '../views/EffectPreviewView';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { Article } from '../model/Feed';

@Entry
@ComponentV2
struct Index {
  @Local currentTab: number = CommonConstants.DEFAULT_TAB_INDEX;
  @Local navPathStack: NavPathStack = new NavPathStack();
  private tabsController: HdsTabsController = new HdsTabsController();
  /** 每个页签独立的 Scroller：绑定给 HdsNavigation 做滚动联动，互不干扰。 */
  private homeScroller: Scroller = new Scroller();
  private subsScroller: Scroller = new Scroller();
  private settingsScroller: Scroller = new Scroller();
  /** 目的页各自的 Scroller：绑定给对应 HdsNavDestination，让标题栏材质随其滚动跟手渐变。 */
  private feedArticlesScroller: Scroller = new Scroller();
  private articleScroller: Scroller = new Scroller();

  /**
   * 各目的页自己的转场状态（自右滑入 + 淡入）。
   * customTransition 的代理对「进入的页」和「被覆盖的页」都会调用，共用一份状态会互相打架，
   * 所以每个目的页各持有一份 slide / alpha。
   */
  @Local articleSlideX: string = '0%';
  @Local articleAlpha: number = 1;
  @Local feedSlideX: string = '0%';
  @Local feedAlpha: number = 1;
  @Local effectSlideX: string = '0%';
  @Local effectAlpha: number = 1;

  aboutToAppear(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    settingsViewModel.init(context as common.Context);
    feedViewModel.init(context as common.Context);
  }

  aboutToDisappear(): void {
    antiPeep.stop();
    gripSensor.stop();
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
    if (this.currentTab === TabIndex.SUBSCRIPTIONS) {
      return this.subsScroller;
    }
    if (this.currentTab === TabIndex.SETTINGS) {
      return this.settingsScroller;
    }
    return this.homeScroller;
  }

  /** 根标题：随当前页签变化。 */
  private rootTitle(): ResourceStr {
    if (this.currentTab === TabIndex.SUBSCRIPTIONS) {
      return $r('app.string.subs_title');
    }
    if (this.currentTab === TabIndex.SETTINGS) {
      return $r('app.string.settings_title');
    }
    return $r('app.string.home_title');
  }

  /**
   * 详情页标题：显示当前文章的标题（落在返回键右侧的标题栏位置），
   * 原地切上一篇/下一篇或换文时随 @Trace 的当前文章一起刷新；无文章时退回通用「文章」。
   */
  private articleTitle(): ResourceStr {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || article.title.length === 0) {
      return $r('app.string.article_title');
    }
    return article.title;
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
   * 标题栏背板底色。
   *
   * 沉浸光感的视觉层级在 backgroundColor 之下：材质会渲染时底色必须留透明，否则会盖住材质
   * （见沉浸光感 FAQ「背景色或背景模糊遮挡材质效果」）；材质不可用（总开关关闭 / 设备不支持）时
   * 才补一层系统灰底，保证内容从标题栏下方穿过时标题仍看得清。
   */
  private titleBackdropColor(): ResourceColor {
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
  private materialTitleStyle(): TitleBarStyleOptions {
    const backdrop: ResourceColor = this.titleBackdropColor();
    const original: HdsNavigationTitleBarStyle = {
      backgroundStyle: { backgroundColor: Color.Transparent }
    };
    const scrolled: HdsNavigationTitleBarStyle = {
      backgroundStyle: { backgroundColor: backdrop }
    };
    const scrollEffectOpts: ScrollEffectOptions = {
      enableScrollEffect: true,
      scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
      blurEffectiveStartOffset: LengthMetrics.vp(0),
      blurEffectiveEndOffset: LengthMetrics.vp(CommonConstants.TITLE_MATERIAL_FADE_VP)
    };
    const style: TitleBarStyleOptions = {
      scrollEffectOpts: scrollEffectOpts,
      originalStyle: original,
      scrollEffectStyle: scrolled,
      systemMaterialEffect: this.materialParams()
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
  private titleOptions(mainTitle: ResourceStr): HdsNavigationTitleBarOptions {
    const title: HdsNavigationTitle = { mainTitle: mainTitle };
    const content: TitleBarContentOptions = { title: title };
    const options: HdsNavigationTitleBarOptions = {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false,
      content: content,
      style: this.materialTitleStyle()
    };
    return options;
  }

  /**
   * 常驻材质标题栏样式：不做「滚动渐显」，背板与材质一直在。
   *
   * 详情页的正文是 Web / Reader 文档（不是 ArkUI 滚动容器），滚动偏移没法通过 bindToScrollable
   * 喂给标题栏，渐显永远不会触发；而正文又铺满整页从标题栏下方穿过，若背板透明，文章文字会直接
   * 透到标题下面。所以详情页固定用这一份：观感与首页标题栏滚起来之后一致。
   */
  private stickyTitleStyle(): TitleBarStyleOptions {
    // 详情页正文是 Web / Reader 文档，材质与背景模糊都采样不到它的画面（实测标题栏背后无模糊），
    // 所以这里固定补一层半透明底：标题栏在正文之上始终读得出是一块玻璃面，标题也始终清晰。
    const scrolled: HdsNavigationTitleBarStyle = {
      backgroundStyle: { backgroundColor: $r('app.color.hm_title_scrim') }
    };
    const style: TitleBarStyleOptions = {
      originalStyle: scrolled,
      scrollEffectStyle: scrolled,
      systemMaterialEffect: this.materialParams()
    };
    return style;
  }

  /** 详情页标题栏配置：常驻材质 + 当前文章标题。 */
  private articleTitleOptions(): HdsNavigationTitleBarOptions {
    const title: HdsNavigationTitle = { mainTitle: this.articleTitle() };
    const content: TitleBarContentOptions = { title: title };
    const options: HdsNavigationTitleBarOptions = {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false,
      content: content,
      style: this.stickyTitleStyle()
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
        ArticleDetailView({ scroller: this.articleScroller })
      }
      .titleBar(this.articleTitleOptions())
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_page_transparent'))
      .bindToScrollable([this.articleScroller])
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
    } else if (name === RouterConstants.PAGE_FEED_ARTICLES) {
      HdsNavDestination() {
        FeedArticlesView({ navPathStack: this.navPathStack, scroller: this.feedArticlesScroller })
      }
      .titleBar(this.titleOptions(feedViewModel.detailFeedTitle.length > 0
        ? feedViewModel.detailFeedTitle
        : $r('app.string.feed_articles_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_page_transparent'))
      .bindToScrollable([this.feedArticlesScroller])
      .translate({ x: this.feedSlideX })
      .opacity(this.feedAlpha)
      .customTransition((operation: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
        return this.slideFadeTransition(operation, isEnter,
          (value: string) => {
            this.feedSlideX = value;
          },
          (value: number) => {
            this.feedAlpha = value;
          });
      })
    } else if (name === RouterConstants.PAGE_EFFECT) {
      HdsNavDestination() {
        EffectPreviewView()
      }
      .titleBar(this.titleOptions($r('app.string.effect_title')))
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
            SubscriptionsView({ navPathStack: this.navPathStack, scroller: this.subsScroller })
          }
          .tabBar(this.barBuilder($r('sys.symbol.folder'), $r('app.string.tab_subs'), this.currentTab === TabIndex.SUBSCRIPTIONS))

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
      .titleBar(this.titleOptions(this.rootTitle()))
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
