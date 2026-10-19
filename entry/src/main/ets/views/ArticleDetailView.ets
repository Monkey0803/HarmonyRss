/*
 * ArticleDetailView.ets — 文章详情（NavDestination 内容，纯展示）。
 *
 * 阅读模式（默认 READER）：把「提取 + 净化」后的结构化正文 HTML 用受控 Reader 文档渲染，
 *   保留段落 / 标题 / 图片 / 列表 / 代码 / 引用，离线可读（正文已缓存到本地库）。
 * 网页原文（WEB）：ArkWeb 直接加载原文链接，作为提取失败或用户主动切换时的兜底。
 * 纯文本（无链接且提取失败时）：退回 feed 文本。
 * 文章标题由 HdsNavDestination 的标题栏显示（见 Index.articleTitle）；正文上方没有信息行，
 * 排版 / 更多 / 模式切换 / 收藏等操作收在贴底的悬浮操作栏里（HDS 悬浮页签栏承载，见 FloatingBar）。
 * 只从 FeedViewModel 读取当前文章与正文，不在视图里做业务逻辑。
 */

import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  HdsSnackBar,
  SnackBarIconOptions,
  SnackBarMessageOptions,
  SnackBarOperationOptions,
  SnackBarStyleOptions,
  SnackBarOperationType,
  HdsTabs,
  HdsTabsController,
  HdsTabsFloatingStyle,
  HdsBarWidthRangeOptions
} from '@kit.UIDesignKit';
import { display, SymbolGlyphModifier } from '@kit.ArkUI';
import { Article } from '../model/Feed';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { safeArea } from '../service/SafeAreaController';
import { MaterialController } from '../service/MaterialController';
import { CommonConstants } from '../common/constants/CommonConstants';
import { articleActions } from '../service/ArticleActions';
import { settingsViewModel } from '../viewmodel/SettingsViewModel';
import { ChoiceOption, READER_FONT_OPTIONS } from '../model/SettingsOptions';
import { ToastUtil } from '../common/utils/ToastUtil';
import { readerStyle } from '../service/ReaderStyle';
import { buildReaderDocument } from '../service/ReaderDocument';
import { appSettings } from '../model/AppSettings';
import { ReaderTypography } from '../common/constants/SettingsConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'ArticleDetailView';

/** 阅读模式：reader = 结构化正文；web = 网页原文。 */
const MODE_READER: string = 'reader';
const MODE_WEB: string = 'web';

/** 横向滑动手势的触发距离（vp）：左滑下一篇、右滑上一篇。 */
const SWIPE_DISTANCE_VP: number = 60;
/** 过度滚动触发「触底检测」的最小位移（vp）。 */
const OVERSCROLL_TRIGGER_VP: number = 24;

/** 空文章占位：@Builder 内不能声明局部变量，用辅助方法返回兜底对象避免 undefined 判空。 */
const EMPTY_ARTICLE: Article = new Article('', '', '', '', '', '', '', 0);

@ComponentV2
export struct ArticleDetailView {
  /** 当前阅读模式。 */
  @Local viewMode: string = MODE_READER;
  @Local loading: boolean = true;
  /** 提取失败：可退网页原文 / 纯文本。 */
  @Local readerFailed: boolean = false;
  /** 已提取并净化好的正文片段（由 ViewModel 提供，命中本地缓存时无需联网）。 */
  @Local readerHtml: string = '';
  private readerController: webview.WebviewController = new webview.WebviewController();
  private webController: webview.WebviewController = new webview.WebviewController();
  /** 提取正文模式的可滚动控制器（由外层 HdsNavDestination 绑定，用于标题栏材质随滚动跟手渐变 + 阅读进度）。 */
  @Param scroller: Scroller = new Scroller();
  /** 网页原文只在首次加载完成时恢复一次进度，避免页面内跳转后又被拉回去。 */
  private webProgressRestored: boolean = false;
  private readerProgressRestored: boolean = false;
  /** 已滑到文末：不再写回滚动进度，让下次打开从头开始。 */
  private finished: boolean = false;
  /** 触底检测在途标记（避免过度滚动事件重复触发 runJavaScript）。 */
  private bottomCheckPending: boolean = false;
  /** 悬浮操作栏的页签控制器（页签栏只作为沉浸光感的生效区域）。 */
  private barTabsController: HdsTabsController = new HdsTabsController();

  private hostContext(): common.UIAbilityContext {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    return context as common.UIAbilityContext;
  }

  private toast(message: ResourceStr): void {
    ToastUtil.show(this.getUIContext(), message);
  }

  /** 当前文章；不存在返回空占位（供 @Builder 直接取字段）。 */
  private cur(): Article {
    const article: Article | undefined = feedViewModel.currentArticle();
    return article === undefined ? EMPTY_ARTICLE : article;
  }

  /** 是否存在当前文章。 */
  private hasArticle(): boolean {
    return feedViewModel.currentArticle() !== undefined;
  }

  /**
   * 即时操作弹窗（HdsSnackBar）：比 Toast 更适合「已完成 + 可关闭」的反馈。
   * 每次按需创建实例，避免在组件字段里提前拿 UIContext。
   */
  private snack(title: ResourceStr): void {
    const bar: HdsSnackBar = new HdsSnackBar(this.getUIContext());
    const icon: SnackBarIconOptions = { icon: $r('sys.symbol.checkmark_circle') };
    const message: SnackBarMessageOptions = { title: title };
    const operation: SnackBarOperationOptions = {
      operationType: SnackBarOperationType.CLOSE_BUTTON_ONLY,
      closeButtonAccessibilityText: $r('app.string.snack_dismiss')
    };
    const style: SnackBarStyleOptions = { duration: 3000 };
    bar.show(icon, message, operation, style);
  }

  private async copyLink(article: Article): Promise<void> {
    const ok: boolean = await articleActions.copyText(article.link.length > 0 ? article.link : article.title);
    if (ok) {
      this.snack($r('app.string.snack_link_copied'));
    } else {
      this.toast($r('app.string.toast_action_failed'));
    }
  }

  private async openInBrowser(article: Article): Promise<void> {
    const ok: boolean = await articleActions.openInBrowser(this.hostContext(), article.link);
    if (!ok) {
      this.toast($r('app.string.toast_action_failed'));
    }
  }

  private async shareArticle(article: Article): Promise<void> {
    const ok: boolean = await articleActions.share(this.hostContext(), article.title, article.link);
    if (!ok) {
      this.toast($r('app.string.toast_action_failed'));
    }
  }

  /** 开始（或重试）提取正文。失败时退到网页原文。 */
  private async startReader(): Promise<void> {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined) {
      return;
    }
    this.readerFailed = false;
    this.loading = true;
    this.finished = false;
    const webMounted: boolean = this.readerHtml.length > 0;
    try {
      const html: string = await feedViewModel.loadReaderHtml(article.id);
      if (html.length > 0) {
        this.readerHtml = html;
        this.viewMode = MODE_READER;
        if (webMounted) {
          // Web 已挂载（原地切文）：直接换文档，避免销毁重建导致 controller 失效。
          this.loadReaderDocIntoWeb();
        }
        // 否则由 onControllerAttached 在新 Web 挂载时加载。
      } else {
        this.onReaderFailed();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'reader extract failed: %{public}d', error.code);
      this.onReaderFailed();
    }
  }

  /** 把当前 readerHtml 载入已挂载的 Reader Web。 */
  private loadReaderDocIntoWeb(): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || this.readerHtml.length === 0) {
      return;
    }
    const doc: string = buildReaderDocument(this.readerHtml, safeArea.contentTopInsetVp, safeArea.contentBottomInsetVp);
    try {
      this.readerController.loadData(doc, 'text/html', 'UTF-8', article.link);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'load reader doc failed: %{public}d', error.code);
    }
  }

  /** 提取失败：有链接就退网页原文，否则退纯文本（loading 由对应视图的 onPageEnd 收尾）。 */
  private onReaderFailed(): void {
    this.readerFailed = true;
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article !== undefined && article.link.length > 0) {
      this.viewMode = MODE_WEB;
      this.loading = true;
      this.toast($r('app.string.article_reader_failed'));
    } else {
      this.viewMode = MODE_READER;
      this.readerHtml = '';
      this.loading = false;
    }
  }

  /** 切换阅读模式。 */
  private switchMode(): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined) {
      return;
    }
    if (this.viewMode === MODE_READER) {
      if (article.link.length === 0) {
        return;
      }
      this.viewMode = MODE_WEB;
      this.loading = true;
    } else {
      this.viewMode = MODE_READER;
      this.startReader();
    }
  }

  /** 原地切换到上一篇 / 下一篇 / 下一条未读（不重新 push 路由）。 */
  private openRelative(id: string): void {
    if (id.length === 0) {
      return;
    }
    feedViewModel.openArticle(id);
    // 不重置 readerHtml：保持 Reader Web 挂载，随后直接换文档，避免 controller 失效。
    this.readerFailed = false;
    this.webProgressRestored = false;
    this.readerProgressRestored = false;
    this.finished = false;
    this.loading = true;
    if (this.viewMode === MODE_READER) {
      this.startReader();
    }
    // 网页原文模式：Web 的 src 随 article.link 变化自动重载，等 onPageEnd 收尾。
  }

  /** 重新提取正文：清掉缓存后重跑（不卸载 Reader Web，直接换文档）。 */
  private retryReader(): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined) {
      return;
    }
    feedViewModel.clearReaderHtml(article.id);
    this.readerFailed = false;
    this.readerProgressRestored = false;
    this.finished = false;
    this.viewMode = MODE_READER;
    this.startReader();
  }

  /** 横向滑动：左滑下一篇、右滑上一篇（竖向留给正文滚动）。 */
  private onHorizontalPan(deltaX: number): void {
    if (deltaX < 0) {
      this.openRelative(feedViewModel.nextArticleId());
    } else {
      this.openRelative(feedViewModel.prevArticleId());
    }
  }

  /**
   * 过度滚动（触顶/触底）时检测是否已到文末；到达则标记「已读完」。
   * 不依赖过度滚动的正负号（不同内核方向约定不一致），统一用网页里的 scrollY 判定。
   */
  private checkReachedBottom(controller: webview.WebviewController): void {
    if (this.finished || this.bottomCheckPending) {
      return;
    }
    this.bottomCheckPending = true;
    controller.runJavaScript(
      '(window.scrollY + window.innerHeight >= document.body.scrollHeight - 8) ? "1" : "0"',
      (err: BusinessError, value: string) => {
        this.bottomCheckPending = false;
        if (err) {
          return;
        }
        if (value.indexOf('1') < 0) {
          return;
        }
        const article: Article | undefined = feedViewModel.currentArticle();
        if (article !== undefined) {
          this.finished = true;
          feedViewModel.markFinished(article.id);
        }
      });
  }

  /**
   * 菜单项前置图标：HM Symbol 必须走 symbolStartIcon（startIcon 不支持符号图标）。
   * 尺寸与页面里其它图标一致。
   */
  private menuIcon(icon: Resource): SymbolGlyphModifier {
    const modifier: SymbolGlyphModifier = new SymbolGlyphModifier(icon);
    modifier.fontSize($r('app.float.icon_size'));
    return modifier;
  }

  /** 溢出菜单：重新提取 / 复制链接 / 浏览器打开 / 分享。 */
  @Builder
  ActionsMenu(article: Article) {
    Menu() {
      MenuItem({
        content: $r('app.string.action_reader_retry'),
        symbolStartIcon: this.menuIcon($r('sys.symbol.arrow_clockwise'))
      })
        .onClick(() => {
          this.retryReader();
        })
      MenuItem({
        content: $r('app.string.action_copy_link'),
        symbolStartIcon: this.menuIcon($r('sys.symbol.link'))
      })
        .onClick(() => {
          this.copyLink(article);
        })
      MenuItem({
        content: $r('app.string.action_open_browser'),
        symbolStartIcon: this.menuIcon($r('sys.symbol.arrow_right_up_and_square'))
      })
        .onClick(() => {
          this.openInBrowser(article);
        })
      MenuItem({
        content: $r('app.string.action_share'),
        symbolStartIcon: this.menuIcon($r('sys.symbol.share'))
      })
        .onClick(() => {
          this.shareArticle(article);
        })
    }
    .radius($r('app.float.radius_card'))
  }

  /**
   * 阅读排版快捷菜单：不必跳设置页就能换正文字号。
   * Reader 文档内联 CSS：改完重建文档重新加载；网页原文靠注入（幂等）。
   */
  @Builder
  FontMenu() {
    Menu() {
      ForEach(READER_FONT_OPTIONS.options, (option: ChoiceOption) => {
        MenuItem({ content: option.label })
          .contentFontColor(appSettings.readerFont === option.id
            ? $r('app.color.hm_brand')
            : $r('app.color.hm_text_primary'))
          .onClick(() => {
            this.applyFontSize(option.id);
          })
      }, (option: ChoiceOption) => option.id)
    }
    .radius($r('app.float.radius_card'))
  }

  private applyFontSize(id: string): void {
    settingsViewModel.setReaderFont(id);
    if (this.viewMode === MODE_READER && this.readerHtml.length > 0) {
      this.loadReaderDocIntoWeb();
    } else if (this.viewMode === MODE_WEB) {
      readerStyle.apply(this.webController);
    }
  }

  aboutToAppear(): void {
    this.startReader();
  }

  /** 离开详情页：按当前模式取一次滚动位置写回。 */
  aboutToDisappear(): void {
    if (this.viewMode === MODE_WEB) {
      this.persistWebProgress();
    } else {
      this.persistReaderProgress();
    }
  }

  /** 提取正文：进入页面时恢复到上次读到的位置（ArkUI Scroll 的 offset，vp）。 */
  private restoreTextProgress(): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || article.progress <= 0) {
      return;
    }
    this.scroller.scrollTo({ xOffset: 0, yOffset: article.progress });
  }

  /**
   * 网页 / Reader 文档：首次加载完成后恢复进度；保存的也是 CSS px（window.scrollY），坐标系一致。
   *
   * 注意不能只 scrollTo 一次：SPA 在 onPageEnd 之后还会继续长内容，那时文档还太短，
   * 一次性滚动会被忽略 / 被后续渲染顶掉。所以注入一段带重试的脚本，每 250ms 校正一次，
   * 最多 3 秒，或者一旦真的落到目标位置就停。
   */
  private restoreScrollProgress(controller: webview.WebviewController, restored: boolean): void {
    if (restored) {
      return;
    }
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || article.progress <= 0) {
      return;
    }
    const target: string = Math.round(article.progress).toString();
    const script: string = '(function(){var y=' + target + ';var n=0;' +
      'var iv=setInterval(function(){window.scrollTo(0,y);n++;' +
      'if(n>12||window.scrollY>=y-4){clearInterval(iv);}},250);})()';
    controller
      .runJavaScript(script)
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'restore progress failed: %{public}d', err.code);
      });
  }

  private restoreWebProgress(): void {
    if (this.webProgressRestored) {
      return;
    }
    this.webProgressRestored = true;
    this.restoreScrollProgress(this.webController, false);
  }

  private restoreReaderProgress(): void {
    if (this.readerProgressRestored) {
      return;
    }
    this.readerProgressRestored = true;
    this.restoreScrollProgress(this.readerController, false);
  }

  /**
   * 网页原文的进度只能在页面里读：window.scrollY。
   * 回调是异步的，组件此时可能已在销毁中；即使失败也只是「这次没记住」，不影响阅读。
   */
  private persistWebProgress(): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || article.link.length === 0 || this.finished) {
      return;
    }
    this.readScrollY(this.webController, article.id);
  }

  private persistReaderProgress(): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || this.readerHtml.length === 0 || this.finished) {
      return;
    }
    this.readScrollY(this.readerController, article.id);
  }

  private readScrollY(controller: webview.WebviewController, articleId: string): void {
    controller.runJavaScript('window.scrollY', (err: BusinessError, value: string) => {
      if (err) {
        hilog.warn(DOMAIN, TAG, 'read scrollY failed: %{public}d', err.code);
        return;
      }
      const y: number = Number(value);
      if (Number.isFinite(y) && y >= 0) {
        feedViewModel.saveProgress(articleId, y);
      }
    });
  }

  /**
   * 阅读导航：上一篇（在当前筛选范围内原地切换）。
   * 图标化后把文字挪到无障碍标签，读屏仍能念出「上一篇 / 下一篇 / 下一条未读」。
   */
  @Builder
  PrevNav() {
    SymbolGlyph($r('sys.symbol.chevron_left'))
      .fontSize($r('app.float.icon_size'))
      .fontColor([feedViewModel.prevArticleId().length > 0
        ? $r('app.color.hm_brand') : $r('sys.color.font_tertiary')])
      .padding($r('app.float.space_xs'))
      .enabled(feedViewModel.prevArticleId().length > 0)
      .accessibilityText($r('app.string.article_prev'))
      .onClick(() => {
        this.openRelative(feedViewModel.prevArticleId());
      })
  }

  /** 阅读导航：下一篇。 */
  @Builder
  NextNav() {
    SymbolGlyph($r('sys.symbol.chevron_right'))
      .fontSize($r('app.float.icon_size'))
      .fontColor([feedViewModel.nextArticleId().length > 0
        ? $r('app.color.hm_brand') : $r('sys.color.font_tertiary')])
      .padding($r('app.float.space_xs'))
      .enabled(feedViewModel.nextArticleId().length > 0)
      .accessibilityText($r('app.string.article_next'))
      .onClick(() => {
        this.openRelative(feedViewModel.nextArticleId());
      })
  }

  /** 阅读导航：下一条未读（底栏的主操作，随握持手镜像左右）。信封 + 未读点。 */
  @Builder
  NextUnreadNav() {
    SymbolGlyph($r('sys.symbol.envelope_badge_dot'))
      .fontSize($r('app.float.icon_size'))
      .fontColor([feedViewModel.nextUnreadId().length > 0
        ? $r('app.color.hm_brand') : $r('sys.color.font_tertiary')])
      .padding($r('app.float.space_xs'))
      .enabled(feedViewModel.nextUnreadId().length > 0)
      .accessibilityText($r('app.string.article_next_unread'))
      .onClick(() => {
        this.openRelative(feedViewModel.nextUnreadId());
      })
  }

  /** 底栏操作：阅读排版（就地换正文字号）。 */
  @Builder
  FontAction() {
    SymbolGlyph($r('sys.symbol.textformat'))
      .fontSize($r('app.float.icon_size'))
      .fontColor([$r('sys.color.font_primary')])
      .padding($r('app.float.space_xs'))
      .accessibilityText($r('app.string.row_reader_font'))
      .bindMenu(this.FontMenu())
  }

  /** 底栏操作：溢出菜单（重新提取 / 复制链接 / 浏览器打开 / 分享）。 */
  @Builder
  MoreAction() {
    SymbolGlyph($r('sys.symbol.more'))
      .fontSize($r('app.float.icon_size'))
      .fontColor([$r('sys.color.font_primary')])
      .padding($r('app.float.space_xs'))
      .accessibilityText($r('app.string.action_more'))
      .bindMenu(this.ActionsMenu(this.cur()))
  }

  /** 底栏操作：阅读模式切换（Reader ↔ 网页原文）。 */
  @Builder
  ModeAction() {
    SymbolGlyph(this.viewMode === MODE_READER ? $r('sys.symbol.link') : $r('sys.symbol.doc_text'))
      .fontSize($r('app.float.icon_size'))
      .fontColor([$r('sys.color.font_primary')])
      .padding($r('app.float.space_xs'))
      .accessibilityText(this.viewMode === MODE_READER
        ? $r('app.string.article_mode_web')
        : $r('app.string.article_mode_reader'))
      .onClick(() => {
        this.switchMode();
      })
  }

  /** 底栏操作：收藏（实心星 = 已收藏）。 */
  @Builder
  StarAction() {
    SymbolGlyph(this.cur().starred ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
      .fontSize($r('app.float.icon_size'))
      .fontColor([this.cur().starred ? $r('app.color.hm_brand') : $r('sys.color.font_primary')])
      .padding($r('app.float.space_xs'))
      .accessibilityText(this.cur().starred ? $r('app.string.action_unstar') : $r('app.string.action_star'))
      .onClick(() => {
        feedViewModel.toggleStar(this.cur().id);
      })
  }

  /**
   * 悬浮操作栏：阅读导航（上一篇 / 下一篇 / 下一条未读）+ 文章操作
   * （更多 / 排版 / 模式切换 / 收藏），一行铺在 HDS 悬浮页签栏里。
   *
   * 为什么是「页签栏」：沉浸光感是区域级能力 —— 只有 Navigation/NavDestination 标题栏与
   * Tabs 的底部 TabBar 属于生效区域，内容区里给普通容器挂 systemMaterial 会静默失效
   * （系统日志：Material inactive: out of scope）。所以这里用 HdsTabs 的悬浮页签栏承载，
   * 材质走 HDS 轨道（systemMaterialEffect，6.1.0(23) 起），与首页页签栏同一套参数与观感。
   *
   * 智感握姿：交给 HdsTabsFloatingStyle.adaptToHandedness（与首页页签栏同一个原生开关），
   * 整条悬浮栏在左右之间平移 —— 因此栏宽要留出侧移余量，见 barWidthVp。
   */
  @Builder
  BarContent() {
    Row({ space: $r('app.float.space_s') }) {
      this.PrevNav()
      this.NextNav()
      this.NextUnreadNav()
      Blank()
      this.MoreAction()
      this.FontAction()
      this.ModeAction()
      this.StarAction()
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 悬浮操作栏样式：与首页悬浮页签栏同一套（沉浸光感材质 + 智感握姿 + 底部避让）。
   *
   * barWidth 三个断点必须显式锁成同一个值：不设的话系统会按断点套默认宽度，
   * 悬浮栏（及其玻璃背板）会比内容窄，图标就露在背板外面。
   */
  private barFloatingStyle(): HdsTabsFloatingStyle {
    const width: number = this.barWidthVp();
    // 三个断点锁成同一个值（同一个值也要各自写全，对象字面量必须对应声明类型）。
    const widths: HdsBarWidthRangeOptions = {
      smallWidth: width,
      mediumWidth: width,
      largeWidth: width
    };
    const style: HdsTabsFloatingStyle = {
      barWidth: widths,
      adaptToHandedness: appSettings.gripEnabled,
      barBottomMargin: safeArea.bottomInsetVp,
      systemMaterialEffect: MaterialController.params(appSettings.materialType,
        appSettings.materialLevel, appSettings.immersiveOn)
    };
    return style;
  }

  /**
   * 悬浮操作栏宽度（vp）：页面宽度减去两侧留白，再额外留出跟手侧移的余量。
   *
   * 智感握姿是「整条悬浮栏左右平移」（adaptToHandedness）；若宽度锁成「页宽 - 2×留白」，
   * 栏就贴满两侧、没有可平移的余量，跟手看不出效果。内容本身 7 个图标只需 ~260vp，
   * 收窄后靠中间的 Blank 吃掉余量即可。
   */
  private barWidthVp(): number {
    try {
      const screenPx: number = display.getDefaultDisplaySync().width;
      return this.getUIContext().px2vp(screenPx)
        - 2 * CommonConstants.BAR_SIDE_MARGIN_VP
        - CommonConstants.BAR_HANDEDNESS_ROOM_VP;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'display info failed: %{public}d', error.code);
      return 0;
    }
  }

  /**
   * 操作栏（HdsTabs）在页面里占的条带高度：悬浮页签栏高度 + 系统导航条避让。
   * 只占底部这一条，空页签内容不会盖住正文、也不会吃掉正文的手势。
   */
  private barStripHeight(): number {
    return safeArea.bottomInsetVp + CommonConstants.TAB_BAR_HEIGHT_VP;
  }

  @Builder
  FloatingBar() {
    if (this.hasArticle()) {
      HdsTabs({ controller: this.barTabsController }) {
        // 唯一页签：内容为空 —— 这里只借「底部悬浮页签栏」这个沉浸光感生效区域承载操作栏。
        TabContent() {
        }
        .tabBar(this.BarContent())
      }
      .barPosition(BarPosition.End)
      .barOverlap(true)
      .vertical(false)
      // 禁用左右滑动切页签：页签栏只是容器。
      .scrollable(false)
      .barFloatingStyle(this.barFloatingStyle())
      .width('100%')
      .height(this.barStripHeight())
    }
  }

  /** 加载遮罩：不透明主题面板盖住 Web 默认白底，避免深色主题转场白闪。 */
  @Builder
  LoadingVeil() {
    Column() {
      LoadingProgress()
        .width($r('app.float.web_loading_size'))
        .height($r('app.float.web_loading_size'))
        .color($r('app.color.hm_brand'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.hm_web_surface'))
  }

  /** Reader 模式：结构化正文文档（提取失败时展示重试 / 退网页原文）。 */
  @Builder
  ReaderBody() {
    if (this.hasArticle()) {
      Stack() {
        if (this.readerHtml.length > 0) {
          Web({ src: '', controller: this.readerController })
            .width('100%')
            .height('100%')
            .darkMode(WebDarkMode.Auto)
            .javaScriptAccess(true)
            .domStorageAccess(false)
            .horizontalScrollBarAccess(false)
            .onControllerAttached(() => {
              const doc: string = buildReaderDocument(this.readerHtml, safeArea.contentTopInsetVp, safeArea.contentBottomInsetVp);
              try {
                this.readerController.loadData(doc, 'text/html', 'UTF-8', this.cur().link);
              } catch (err) {
                const error: BusinessError = err as BusinessError;
                hilog.warn(DOMAIN, TAG, 'load reader doc failed: %{public}d', error.code);
              }
            })
            .onPageEnd(() => {
              this.loading = false;
              this.restoreReaderProgress();
            })
            .onOverScroll((event: OnOverScrollEvent) => {
              if (Math.abs(event.yOffset) >= OVERSCROLL_TRIGGER_VP) {
                this.checkReachedBottom(this.readerController);
              }
            })
            // 横向滑动切文：priorityGesture + IgnoreInternal 才能抢在 ArkWeb 内部手势之前。
            .priorityGesture(
              PanGesture({ direction: PanDirection.Horizontal, distance: SWIPE_DISTANCE_VP })
                .onActionEnd((event: GestureEvent) => {
                  this.onHorizontalPan(event.offsetX);
                }),
              GestureMask.IgnoreInternal
            )
        } else {
          // 无正文可读（提取失败且无链接）：退纯文本。
          this.TextBody()
        }

        if (this.loading && this.readerHtml.length > 0) {
          this.LoadingVeil()
        }
      }
      .width('100%')
      .height('100%')
      .clip(true)
    }
  }

  /** 网页原文：全文阅读（兜底）。 */
  @Builder
  WebBody() {
    if (this.hasArticle()) {
      Stack() {
        Web({ src: this.cur().link, controller: this.webController })
          .width('100%')
          .height('100%')
          .darkMode(WebDarkMode.Auto)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .onPageEnd(() => {
            this.loading = false;
            // 网页原文的排版只能靠注入：按设置覆盖正文字号 / 行距。
            readerStyle.apply(this.webController);
            // 排版注入完成后再恢复进度，避免字号变化导致落点偏移。
            this.restoreWebProgress();
          })
          .onOverScroll((event: OnOverScrollEvent) => {
            if (Math.abs(event.yOffset) >= OVERSCROLL_TRIGGER_VP) {
              this.checkReachedBottom(this.webController);
            }
          })
          // 横向滑动切上一篇/下一篇：绑在 Web 上（横向不与 Web 竖向滚动竞争）。
          // 横向滑动切文：priorityGesture + IgnoreInternal 才能抢在 ArkWeb 内部手势之前。
          .priorityGesture(
            PanGesture({ direction: PanDirection.Horizontal, distance: SWIPE_DISTANCE_VP })
              .onActionEnd((event: GestureEvent) => {
                this.onHorizontalPan(event.offsetX);
              }),
            GestureMask.IgnoreInternal
          )

        if (this.loading) {
          this.LoadingVeil()
        }
      }
      .width('100%')
      .height('100%')
      .clip(true)
    }
  }

  /** 提取正文兜底：feed 里能拿到的纯文本 + 原文链接。 */
  @Builder
  TextBody() {
    if (this.hasArticle()) {
      Scroll(this.scroller) {
        Column({ space: $r('app.float.space_m') }) {
          // 透明标题栏占位：放在滚动内容里（不是外层固定占位），正文才会从标题栏下方穿过。
          Row().width('100%').height(safeArea.contentTopInsetVp)

          Text(this.cur().content.length > 0 ? this.cur().content : $r('app.string.article_no_content'))
            .fontSize(ReaderTypography.fontSize(appSettings.readerFont))
            .lineHeight(ReaderTypography.fontSize(appSettings.readerFont)
              * ReaderTypography.lineHeight(appSettings.readerLine))
            .fontColor($r('app.color.hm_text_primary'))
            .width('100%')

          if (this.cur().link.length > 0) {
            Column({ space: $r('app.float.space_xs') }) {
              Text($r('app.string.article_open_link'))
                .fontSize($r('app.float.font_size_section'))
                .fontColor($r('app.color.hm_text_secondary'))
              Text(this.cur().link)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_brand'))
                .width('100%')
            }
            .width('100%')
            .padding($r('app.float.space_m'))
            .backgroundColor($r('app.color.hm_card_background'))
            .borderRadius($r('app.float.radius_card'))
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .padding({
          left: $r('app.float.space_l'),
          right: $r('app.float.space_l'),
          // 底部预留：让文末文字能滚到悬浮底栏之上（含系统导航条避让）。
          bottom: safeArea.contentBottomInsetVp
        })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .clip(false)
      .align(Alignment.TopStart)
      .onAppear(() => {
        this.restoreTextProgress();
      })
      .onScrollStop(() => {
        const current: Article | undefined = feedViewModel.currentArticle();
        if (current !== undefined) {
          feedViewModel.saveProgress(current.id, this.scroller.currentOffset().yOffset);
        }
      })
    }
  }

  /**
   * 内容切换：网页原文（有链接）或 Reader。所有子 builder 均为无参 ——
   * ArkUI 的 @Builder 按值传参不会随参数变化刷新，因此这里统一让子 builder 自己读 ViewModel，
   * 由 @Trace currentArticleId 驱动整页重建。
   */
  @Builder
  BodySwitch() {
    if (this.hasArticle()) {
      if (this.viewMode === MODE_WEB && this.cur().link.length > 0) {
        this.WebBody()
      } else {
        this.ReaderBody()
      }
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 正文铺满整页（含标题栏与悬浮底栏下方），从两栏下方穿过 —— 与首页 barOverlap(true) 同源；
      // 首尾让位由正文自己留：Reader 文档 / 网页原文走 CSS 内边距，纯文本走滚动内容里的占位与底部内边距。
      this.BodySwitch()

      this.FloatingBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
