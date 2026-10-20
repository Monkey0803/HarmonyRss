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
  BottomBuilderShowType,
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
  SystemMaterialParams,
  HdsTabsMiniBar,
  HdsBarStyle,
  HdsTabsBarChangeMode,
  HdsBarWidthRangeOptions
} from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { appSettings } from '../model/AppSettings';
import { settingsViewModel } from '../viewmodel/SettingsViewModel';
import { settingsStore } from '../service/SettingsStore';
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
import { FeedError } from '../common/constants/RssConstants';
import { FeedErrorText } from '../common/utils/FeedErrorText';
import { HomeTabView } from '../views/HomeTabView';
import { FilterSegmentBar } from '../views/FilterSegmentBar';
import { BrandTitle } from '../views/BrandTitle';
import { SettingsTabView } from '../views/SettingsTabView';
import { ImageTabView } from '../views/ImageTabView';
import { PrivacyVeil } from '../views/PrivacyVeil';
import { ArticleDetailView } from '../views/ArticleDetailView';
import { SubscriptionsView } from '../views/SubscriptionsView';
import { FeedArticlesView } from '../views/FeedArticlesView';
import { EffectPreviewView } from '../views/EffectPreviewView';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { deepLink, DEEP_LINK_EVENT, DeepLinkParams } from '../service/DeepLink';
import { Article } from '../model/Feed';

@Entry
@ComponentV2
struct Index {
  @Local currentTab: number = appSettings.lastTabIndex;
  /** 详情页沉浸阅读：由详情页点按正文中部切换，控制 HdsNavDestination 标题栏显隐。 */
  @Local articleBarsHidden: boolean = false;
  /** 添加订阅源面板：显隐、输入地址、提交中（入口在悬浮页签栏的 miniBar 上）。 */
  @Local showAddSheet: boolean = false;
  @Local addUrl: string = '';
  @Local addSubmitting: boolean = false;
  @Local navPathStack: NavPathStack = new NavPathStack();
  private tabsController: HdsTabsController = new HdsTabsController();
  /** 每个页签独立的 Scroller：绑定给 HdsNavigation 做滚动联动，互不干扰。 */
  private homeScroller: Scroller = new Scroller();
  private subsScroller: Scroller = new Scroller();
  private settingsScroller: Scroller = new Scroller();
  /** 目的页各自的 Scroller：绑定给对应 HdsNavDestination，让标题栏材质随其滚动跟手渐变。 */
  private feedArticlesScroller: Scroller = new Scroller();
  private articleScroller: Scroller = new Scroller();

  /** 收到 Ability 的深链事件后消费（应用已在前台时点卡片的路径）。 */
  private onDeepLinkEvent: () => void = () => {
    this.consumeDeepLink();
  };

  aboutToAppear(): void {
    feedViewModel.subscribeArticles(this.onArticlesReadyDeepLink);
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context !== undefined) {
      context.eventHub.on(DEEP_LINK_EVENT, this.onDeepLinkEvent);
    }
    settingsViewModel.init(context as common.Context);
    feedViewModel.init(context as common.Context);
    // 恢复上次停留的页签（偏好是异步读出来的，两个触发点都调一次，见 restoreTab）。
    settingsViewModel.whenReady().then(() => {
      this.restoreTab();
    });
  }

  /** 分栏模式：宽窗口用 Split，窄窗口用 Stack（单栏）。 */
  private navMode(): NavigationMode {
    return safeArea.wide ? NavigationMode.Split : NavigationMode.Stack;
  }

  /**
   * 回到上次停留的页签（越界时退回首页）。
   *
   * 注意：HdsTabs 的 `index` 必须受控于 `currentTab`（见 build），否则只改状态只会让自绘页签栏
   * 变色、内容区仍停在首页；控制器命令在挂载前发出去会被丢掉，受控 index 没有这个时序问题。
   */
  private restoreTab(): void {
    const max: number = IMAGE_DOMAIN ? TabIndex.IMAGES : TabIndex.SETTINGS;
    const saved: number = appSettings.lastTabIndex;
    this.currentTab = saved >= 0 && saved <= max ? saved : CommonConstants.DEFAULT_TAB_INDEX;
  }

  aboutToDisappear(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context !== undefined) {
      context.eventHub.off(DEEP_LINK_EVENT, this.onDeepLinkEvent);
    }
    feedViewModel.unsubscribeArticles(this.onArticlesReadyDeepLink);
    antiPeep.stop();
    gripSensor.stop();
  }

  /**
   * 消费卡片 / 通知带进来的深链：定位文章并 push 详情页。
   * 必须在回到前台时也跑一次 —— 应用已经在运行时点卡片走的是 onNewWant，页面不会重建。
   */
  private consumeDeepLink(): void {
    const articleId: string = deepLink.peek();
    if (articleId.length > 0) {
      this.tryOpenDeepLink(articleId);
    }
  }

  /**
   * 打开深链文章：成功返回 true。
   *
   * 顺序很关键：**先查（不产生副作用）→ 先清空待处理 id → 再打开**。
   * openArticle 会 publish，publish 会通知列表订阅者（本页也在订阅），
   * 若那时 id 还在，就会递归回到这里（真实踩过：无限递归把页面栈弄坏）。
   */
  private tryOpenDeepLink(articleId: string): boolean {
    if (!feedViewModel.hasArticle(articleId)) {
      return false;
    }
    const action: string = deepLink.takeAction();
    deepLink.take();
    if (action === DeepLinkParams.ACTION_MARK_READ) {
      // 通知上的「标记已读」按钮：只改状态，不抢用户的当前页面。
      feedViewModel.markReadMany([articleId], true);
      return true;
    }
    feedViewModel.openArticleById(articleId);
    // 切回「阅读」页签，再压详情页（页面栈是全局的，不切页签会压在设置页上面）。
    this.currentTab = TabIndex.HOME;
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_ARTICLE, ''));
    return true;
  }

  /**
   * 冷启动时本地缓存是异步读出来的，onPageShow 那一刻文章列表可能还是空的 ——
   * 所以列表第一次有数据后再给深链一次机会；仍然找不到说明文章已被清理，丢弃不再重试。
   */
  private onArticlesReadyDeepLink: () => void = () => {
    const articleId: string = deepLink.peek();
    if (articleId.length === 0 || feedViewModel.articlesTotal === 0) {
      return;
    }
    if (!this.tryOpenDeepLink(articleId)) {
      deepLink.take();
    }
  };

  /** 回到前台（或页面重新显示）时，按设置的自动刷新间隔决定是否抓取。 */
  onPageShow(): void {
    this.consumeDeepLink();
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
   * 标题栏 / 状态栏动态显隐：各由一个设置页开关控制（沉浸光感最佳实践建议都开，这里交给用户）。
   * 标题栏：false（默认）固定不动、内容从标题栏下方滚过；true 滚动时收起。
   * 状态栏：false（默认）常驻；true 滚动内容时一并收起。
   */
  private dynamicHideParams(): DynamicHideParams {
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
   * 根标题栏配置：在「阅读」页签时，标题换成品牌行（logo + HarmonyRss），
   * 并在标题下方挂筛选分段控件。
   *
   * 为什么都挂标题栏：沉浸光感是区域级能力，只有 Navigation/NavDestination 标题栏与横向 Tabs 的
   * 底部 TabBar 里组件才真吃系统材质；放进内容区材质会静默失效。品牌行用 stackBuilder 顶掉文字标题，
   * 筛选条用 bottomBuilder 挂在标题下方（首页内容顶部按 FILTER_BAR_HEIGHT_VP 多留一段占位）。
   */
  private rootTitleOptions(): HdsNavigationTitleBarOptions {
    const isHome: boolean = this.currentTab === TabIndex.HOME;
    const title: HdsNavigationTitle = { mainTitle: isHome ? '' : this.rootTitle() };
    const content: TitleBarContentOptions = { title: title };
    if (isHome) {
      content.stackBuilder = (): void => {
        this.HomeBrandBar();
      };
      content.bottomBuilder = {
        builder: (): void => {
          this.HomeFilterBar();
        },
        height: CommonConstants.FILTER_BAR_HEIGHT_VP,
        showType: BottomBuilderShowType.DIRECTLY_SHOW
      };
    }
    const options: HdsNavigationTitleBarOptions = {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false,
      content: content,
      style: this.materialTitleStyle()
    };
    return options;
  }

  /** 标题栏 stackBuilder：品牌行（logo + HarmonyRss）。 */
  @Builder
  HomeBrandBar() {
    BrandTitle()
  }

  /** 标题栏 bottomBuilder：阅读页签的筛选条。 */
  @Builder
  HomeFilterBar() {
    FilterSegmentBar()
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
      backgroundStyle: { backgroundColor: $r('app.color.hm_glass_scrim') }
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

  private floatingStyle(): HdsTabsFloatingStyle {
    const width: number = CommonConstants.MINI_BAR_WIDTH_VP;
    const miniWidth: HdsBarWidthRangeOptions = {
      smallWidth: width,
      mediumWidth: width,
      largeWidth: width
    };
    const miniBar: HdsTabsMiniBar = {
      miniBarBuilder: () => {
        this.AddMiniBarButton()
      },
      miniBarWidth: miniWidth,
      // 不显式指定 miniBarStyle：HDS 会按设备宽度自适应（宽屏默认展开、窄屏默认折叠），
      // 手机上落到的就是「页签栏展开 + 迷你栏折叠」这一态 —— 与之前的观感一致，
      // 而显式 EXPAND 会把页签栏压成「只留当前页签」（HDS 的折叠语义）。
      onBarStyleChange: (miniBarStyle: HdsBarStyle, tabBarStyle: HdsBarStyle,
        miniBarWidth: number, tabBarWidth: number, mode: HdsTabsBarChangeMode) => {
        // 点 miniBar 在 HDS 里是「切换栏样式」：这里它只是个入口，所以展开后立刻收回来，
        // 同时打开「添加订阅源」面板（APP_TRIGGER 是下面这行自己触发的，不重复处理）。
        if (miniBarStyle === HdsBarStyle.EXPAND && mode !== HdsTabsBarChangeMode.APP_TRIGGER) {
          this.showAddSheet = true;
          this.tabsController.applyMiniBarStyle(HdsBarStyle.COLLAPSE);
        }
      }
    };
    const style: HdsTabsFloatingStyle = {
      adaptToHandedness: appSettings.gripEnabled,
      // 悬浮页签栏默认距 HdsTabs 底部 0vp；全屏布局下会压住系统导航条，这里按避让高度上抬。
      barBottomMargin: safeArea.bottomInsetVp,
      systemMaterialEffect: this.materialParams(),
      miniBar: miniBar
    };
    return style;
  }

  /**
   * 悬浮页签栏上的「添加订阅源」入口（miniBar 承载）。
   *
   * 放在这里的理由：沉浸光感是区域级能力，只有标题栏与横向 Tabs 的底部 TabBar 生效；
   * miniBar 属于悬浮页签栏的一部分，因此能拿到真正的系统材质（首页原来那个内容区自绘悬浮按钮拿不到）。
   */
  @Builder
  AddMiniBarButton() {
    Row() {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([$r('sys.color.font_primary')])
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .accessibilityText($r('app.string.home_add_feed_title'))
    .onClick(() => {
      this.showAddSheet = true;
    })
  }

  /** 添加订阅源底部面板：输入地址 → 校验并入库抓取。 */
  @Builder
  AddFeedSheet() {
    Column({ space: $r('app.float.space_m') }) {
      Text($r('app.string.home_add_feed_title'))
        .fontSize($r('app.float.font_size_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      Row({ space: $r('app.float.space_s') }) {
        TextInput({ text: this.addUrl, placeholder: $r('app.string.subs_url_hint') })
          .type(InputType.Normal)
          .fontSize($r('app.float.font_size_body'))
          .layoutWeight(1)
          .onChange((value: string) => {
            this.addUrl = value;
          })
        Button(this.addSubmitting ? $r('app.string.subs_adding') : $r('app.string.subs_add'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .enabled(!this.addSubmitting)
          .onClick(() => {
            this.submitAdd();
          })
      }
      .width('100%')

      if (feedViewModel.errorCode !== FeedError.NONE) {
        Text(FeedErrorText.of(feedViewModel.errorCode))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
      }
    }
    .width('100%')
    .padding($r('app.float.space_l'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 从悬浮页签栏添加订阅源：成功则清空输入并关闭面板，失败保留输入以便修正。 */
  private async submitAdd(): Promise<void> {
    this.addSubmitting = true;
    const ok: boolean = await feedViewModel.addFeed(this.addUrl);
    this.addSubmitting = false;
    if (ok) {
      this.addUrl = '';
      this.showAddSheet = false;
    }
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

  /**
   * 页签栏的一个入口（自绘）。
   * withBadge=true 时在图标右上角挂未读角标：数量直接读 feedViewModel.unreadTotal，
   * 读的是 @ObservedV2 单例的 @Trace 属性，因此未读数变化会驱动这里重建。
   */
  @Builder
  barBuilder(icon: Resource, label: ResourceStr, active: boolean, withBadge: boolean) {
    Column({ space: $r('app.float.space_xxs') }) {
      if (withBadge && feedViewModel.unreadTotal > 0) {
        Badge({
          count: feedViewModel.unreadTotal,
          maxCount: CommonConstants.BADGE_MAX_COUNT,
          position: BadgePosition.RightTop,
          style: {
            fontSize: $r('app.float.badge_font_size'),
            badgeSize: $r('app.float.badge_size'),
            badgeColor: $r('app.color.hm_brand')
          }
        }) {
          SymbolGlyph(icon)
            .fontSize($r('app.float.tab_icon_size'))
            .fontColor([active ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
        }
      } else {
        SymbolGlyph(icon)
          .fontSize($r('app.float.tab_icon_size'))
          .fontColor([active ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
      }
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
        ArticleDetailView({
          scroller: this.articleScroller,
          navPathStack: this.navPathStack,
          onImmersiveChange: (hidden: boolean) => {
            this.articleBarsHidden = hidden;
          }
        })
      }
      .titleBar(this.articleTitleOptions())
      // 沉浸阅读：详情页点按正文中部时收起 / 恢复标题栏（带系统动画）
      .hideTitleBar(this.articleBarsHidden, true)
      .titleMode(HdsNavDestinationTitleMode.MINI)
      // 不透明背板：原生覆盖式 push 时不会透过新页看到上一页，也不再因淡出透出壁纸。
      .backgroundColor($r('app.color.hm_web_surface'))
      .bindToScrollable([this.articleScroller])
    } else if (name === RouterConstants.PAGE_FEED_ARTICLES) {
      HdsNavDestination() {
        FeedArticlesView({ navPathStack: this.navPathStack, scroller: this.feedArticlesScroller })
      }
      .titleBar(this.titleOptions(feedViewModel.detailFeedTitle.length > 0
        ? feedViewModel.detailFeedTitle
        : $r('app.string.feed_articles_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      // 不透明背板：与详情页一致，走系统原生转场不穿透。
      .backgroundColor($r('app.color.hm_web_surface'))
      .bindToScrollable([this.feedArticlesScroller])
    } else if (name === RouterConstants.PAGE_EFFECT) {
      HdsNavDestination() {
        EffectPreviewView()
      }
      .titleBar(this.titleOptions($r('app.string.effect_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      // 不透明背板：与详情页一致，走系统原生转场不穿透。
      .backgroundColor($r('app.color.hm_web_surface'))
    }
  }

  build() {
    Stack() {
      this.BackgroundLayer()

      HdsNavigation(this.navPathStack) {
        // index 受控于 currentTab：只改状态就能切内容（不用控制器命令，避免挂载时序问题）。
        HdsTabs({ index: this.currentTab, controller: this.tabsController }) {
          TabContent() {
            HomeTabView({
              navPathStack: this.navPathStack,
              scroller: this.homeScroller,
              onAddFeedRequest: () => {
                this.showAddSheet = true;
              }
            })
          }
          .tabBar(this.barBuilder($r('sys.symbol.house'), $r('app.string.tab_home'),
            this.currentTab === TabIndex.HOME, true))

          TabContent() {
            SubscriptionsView({ navPathStack: this.navPathStack, scroller: this.subsScroller })
          }
          .tabBar(this.barBuilder($r('sys.symbol.folder'), $r('app.string.tab_subs'),
            this.currentTab === TabIndex.SUBSCRIPTIONS, false))

          TabContent() {
            SettingsTabView({ navPathStack: this.navPathStack, scroller: this.settingsScroller })
          }
          .tabBar(this.barBuilder($r('sys.symbol.gearshape'), $r('app.string.tab_settings'),
            this.currentTab === TabIndex.SETTINGS, false))

          if (IMAGE_DOMAIN) {
            TabContent() {
              ImageTabView()
            }
            .tabBar(this.barBuilder($r('sys.symbol.picture'), $r('app.string.tab_images'),
              this.currentTab === TabIndex.IMAGES, false))
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
        // 挂载完成后再补一次恢复（whenReady 可能早于挂载，命令会被丢掉）
        .onAppear(() => {
          this.restoreTab();
        })
        .onChange((index: number) => {
          this.currentTab = index;
          // 记住停留的页签：下次打开直接回到这里。
          appSettings.lastTabIndex = index;
          settingsStore.save();
        })
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.hm_page_transparent'))
      }
      // 分栏：宽窗口（折叠屏展开 / 平板）自动切成「左列表 + 右正文」两栏，窄窗口保持单栏堆叠。
      // 断点由 SafeAreaController 依窗口宽度维护（windowSizeChange 时重算）。
      .mode(this.navMode())
      .navBarWidth(CommonConstants.SPLIT_NAV_WIDTH_VP)
      .navBarWidthRange({
        minWidth: CommonConstants.SPLIT_NAV_MIN_VP,
        maxWidth: CommonConstants.SPLIT_NAV_MAX_VP
      })
      .titleBar(this.rootTitleOptions())
      // 紧凑标题栏（默认 FREE 是大标题模式，标题上下留白很大）。
      .titleMode(HdsNavigationTitleMode.MINI)
      // 根页面没有上一级：MINI 模式下会默认显示返回键，这里隐藏。
      .hideBackButton(true)
      .navDestination(this.pageMap)
      // 先声明动态显隐，再绑定可滚动容器 —— 顺序不能反：真机上「先 bindToScrollable 后 dynamicHideTitleBar」
      // 会导致动态显隐完全不生效（已实测），官方样例也是这个顺序。
      .dynamicHideTitleBar(this.dynamicHideParams())
      .bindToScrollable([this.currentScroller()])
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
    .bindSheet(this.showAddSheet, this.AddFeedSheet(), MaterialController.sheetOptions({
      height: 240,
      dragBar: true,
      onDisappear: () => {
        this.showAddSheet = false;
      }
    }, appSettings.immersiveOn))
  }
}
