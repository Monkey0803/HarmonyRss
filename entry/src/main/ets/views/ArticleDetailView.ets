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
import { ReadSettingsSheet } from './ReadSettingsSheet';
import { ToastUtil } from '../common/utils/ToastUtil';
import { toPlainText } from '../common/utils/HtmlText';
import { screenAwake } from '../service/ScreenAwake';
import { readerSpeech } from '../service/ReaderSpeech';
import {
  clearFindScript,
  countFindScript,
  findSupportScript,
  gotoFindScript,
  runFindScript
} from '../service/ReaderFind';
import { readerStyle } from '../service/ReaderStyle';
import { settingsStore } from '../service/SettingsStore';
import { ReaderViewMode } from '../common/constants/RssConstants';
import { buildReaderDocument } from '../service/ReaderDocument';
import {
  applyHighlightsScript,
  gotoHighlightScript,
  gotoRatioScript,
  highlightSupportScript,
  HighlightItem,
  ReaderHighlightBridge,
  selectionRatioScript
} from '../service/ReaderHighlight';
import { Highlight, HighlightColor } from '../model/Highlight';
import { articleStore } from '../service/ArticleStore';
import {
  parsePosition,
  progressListenerScript,
  ReaderPosition,
  ReaderProgressBridge,
  readPositionScript,
  restorePositionScript
} from '../service/ReaderProgress';
import { appSettings } from '../model/AppSettings';
import { ReaderTypography } from '../common/constants/SettingsConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'ArticleDetailView';

/** 阅读模式：reader = 结构化正文；web = 网页原文。 */
// 与偏好里存的值同源：ReaderViewMode 在 RssConstants 定义，这里只做本地别名。
const MODE_READER: string = ReaderViewMode.READER;
const MODE_WEB: string = ReaderViewMode.WEB;

/** 横向滑动手势的触发距离（vp）：左滑下一篇、右滑上一篇。 */
const SWIPE_DISTANCE_VP: number = 60;
/** 过度滚动触发「触底检测」的最小位移（vp）。 */
const OVERSCROLL_TRIGGER_VP: number = 24;

/** 空文章占位：@Builder 内不能声明局部变量，用辅助方法返回兜底对象避免 undefined 判空。 */
const EMPTY_ARTICLE: Article = new Article('', '', '', '', '', '', '', 0);

@ComponentV2
export struct ArticleDetailView {
  /** 当前阅读模式。 */
  @Local viewMode: string = appSettings.readerViewMode;
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
  /** 「阅读排版」半模态面板显隐。 */
  /**
   * 半模态面板当前显示哪一种内容：'' 关闭 / 'read' 阅读排版 / 'hlList' 标注列表 / 'hlEdit' 标注编辑。
   * 一个组件上只能挂一个 bindSheet（挂多个只会生效最后一个），所以用一个状态切换内容。
   */
  @Local sheetMode: string = '';
  /** 半模态显隐（bindSheet 的首参要是纯状态变量，不能传表达式，否则打开不生效）。 */
  @Local showSheet: boolean = false;
  /** 当前阅读进度（0–1），用于标题栏下方的细进度条；由文档内滚动回调刷新。 */
  @Local progressRatio: number = 0;
  /** 正文里选中的文本（Web 的 onTextSelectionChange 回调）；非空时显示「复制/分享选段」浮条。 */
  @Local selectedText: string = '';
  /** 当前文章的标注（本地库读出；正文里靠注入脚本重放高亮）。 */
  @Local highlights: Highlight[] = [];
  /** 正在编辑的标注（弹面板改备注 / 改色 / 删除）。 */
  @Local editingHighlightId: string = '';
  /** 备注输入草稿。 */
  @Local noteDraft: string = '';
  /** 切文动效：正文容器的临时位移/透明度（animateTo 收尾回 0 / 1）。 */
  @Local bodyShift: number = 0;
  @Local bodyAlpha: number = 1;
  /** 朗读：是否正在朗读（控制迷你播放条与菜单文案）。 */
  @Local speaking: boolean = false;
  /** 沉浸阅读：隐藏标题栏与底栏（点按正文中部切换）。 */
  @Local barsHidden: boolean = false;
  /** 横向手势的起手点（px），用于避让系统边缘返回手势。 */
  private panStartX: number = -1;
  /** 沉浸态切换上报给外壳（标题栏由 HdsNavDestination.hideTitleBar 控制）。 */
  @Event onImmersiveChange: (hidden: boolean) => void = () => {};
  /** 导航栈：「只看该源」要退回首页列表（范围 chip 在首页顶部）。 */
  @Param navPathStack: NavPathStack = new NavPathStack();
  /** 文内查找：查找条显隐、查询串、命中数与当前下标。 */
  @Local findOpen: boolean = false;
  @Local findQuery: string = '';
  @Local findCount: number = 0;
  @Local findIndex: number = 0;
  /** 当前文章纯文本缓存（复制正文 / 分享正文 / 朗读用）：按文章 id 失效。 */
  private plainTextCache: string = '';
  private plainTextCacheId: string = '';
  /** 排版变化（重建 Reader 文档）后要落回的位置；undefined 表示无需特殊恢复。 */
  private pendingRestore: ReaderPosition | undefined = undefined;
  /** 文档内点标注 → ArkTS 弹编辑面板（javaScriptProxy，页面创建时注册一次）。 */
  private hlBridge: ReaderHighlightBridge = new ReaderHighlightBridge((id: string) => {
    this.openHighlightEditor(id);
  });
  /** 文档内滚动 → ArkTS 的进度回调（javaScriptProxy，页面创建时注册一次）。 */
  private progressBridge: ReaderProgressBridge = new ReaderProgressBridge((ratio: number) => {
    this.progressRatio = ratio;
  });
  /** 正文触摸判定（沉浸阅读的点按）：按下位置与时间。 */
  private tapStartX: number = -1;
  private tapStartY: number = -1;
  private tapStartTime: number = 0;
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

  /** 当前文章纯文本（提取后的正文优先，兜底用 feed 里的纯文本）。 */
  private plainText(): string {
    const article: Article = this.cur();
    if (this.plainTextCacheId !== article.id) {
      // 优先用提取时落库的纯文本；没有（未提取过）再就近从 readerHtml / feed 正文现算。
      if (article.plainText.length > 0) {
        this.plainTextCache = article.plainText;
      } else {
        const source: string = this.readerHtml.length > 0 ? this.readerHtml : article.content;
        this.plainTextCache = toPlainText(source);
      }
      this.plainTextCacheId = article.id;
    }
    return this.plainTextCache;
  }

  /** 当前正文 Web 的控制器（查找 / 高亮都作用于它）。 */
  private bodyController(): webview.WebviewController {
    return this.viewMode === MODE_WEB ? this.webController : this.readerController;
  }

  /** 打开查找条：注入高亮支持（幂等），并聚焦输入框由用户输入。 */
  private openFind(): void {
    this.findOpen = true;
    this.findQuery = '';
    this.findCount = 0;
    this.findIndex = 0;
    this.bodyController()
      .runJavaScript(findSupportScript())
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'find support failed: %{public}d', err.code);
      });
  }

  /** 查询串变化：清掉旧高亮，重新查找并跳到第一个命中项。 */
  private applyFind(query: string): void {
    this.findQuery = query;
    if (query.length === 0) {
      this.clearFind();
      return;
    }
    const controller: webview.WebviewController = this.bodyController();
    controller
      .runJavaScript(findSupportScript())
      .then(() => controller.runJavaScript(runFindScript(query)))
      .then((raw: string) => {
        const total: number = Number(raw);
        this.findCount = Number.isFinite(total) && total > 0 ? total : 0;
        this.findIndex = this.findCount > 0 ? 0 : -1;
        if (this.findCount > 0) {
          this.gotoFind(0);
        }
      })
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'find failed: %{public}d', err.code);
      });
  }

  /** 下一个 / 上一个命中项（循环）。 */
  private stepFind(delta: number): void {
    if (this.findCount <= 0) {
      return;
    }
    const next: number = (this.findIndex + delta + this.findCount) % this.findCount;
    this.gotoFind(next);
  }

  private gotoFind(index: number): void {
    this.findIndex = index;
    this.bodyController()
      .runJavaScript(gotoFindScript(index))
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'find goto failed: %{public}d', err.code);
      });
  }

  /** 关闭查找条：清掉高亮。 */
  private closeFind(): void {
    this.findOpen = false;
    this.clearFind();
  }

  private clearFind(): void {
    this.findCount = 0;
    this.findIndex = 0;
    this.bodyController()
      .runJavaScript(clearFindScript())
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'find clear failed: %{public}d', err.code);
      });
  }

  /** 开始 / 停止朗读（不支持时提示，不影响阅读）。 */
  private async toggleSpeech(): Promise<void> {
    if (this.speaking) {
      readerSpeech.stop();
      return;
    }
    const text: string = this.plainText();
    if (text.length === 0) {
      this.toast($r('app.string.article_no_content'));
      return;
    }
    const ok: boolean = await readerSpeech.start(text, (speaking: boolean) => {
      this.speaking = speaking;
    });
    if (!ok) {
      this.toast($r('app.string.toast_speech_unsupported'));
    }
  }

  private async copyBody(): Promise<void> {
    const text: string = this.plainText();
    if (text.length === 0) {
      this.toast($r('app.string.article_no_content'));
      return;
    }
    const ok: boolean = await articleActions.copyText(text);
    if (ok) {
      this.snack($r('app.string.snack_body_copied'));
    } else {
      this.toast($r('app.string.toast_action_failed'));
    }
  }

  private async shareBody(): Promise<void> {
    const text: string = this.plainText();
    if (text.length === 0) {
      this.toast($r('app.string.article_no_content'));
      return;
    }
    const ok: boolean = await articleActions.shareText(this.hostContext(), this.cur().title, text);
    if (!ok) {
      this.toast($r('app.string.toast_action_failed'));
    }
  }

  private async copySelection(): Promise<void> {
    const ok: boolean = await articleActions.copyText(this.selectedText);
    this.selectedText = '';
    if (ok) {
      this.snack($r('app.string.snack_selection_copied'));
    } else {
      this.toast($r('app.string.toast_action_failed'));
    }
  }

  private async shareSelection(): Promise<void> {
    const text: string = this.selectedText;
    this.selectedText = '';
    const ok: boolean = await articleActions.shareText(this.hostContext(), this.cur().title, text);
    if (!ok) {
      this.toast($r('app.string.toast_action_failed'));
    }
  }

  /**
   * 正文里的链接拦截：放行文档自身（Reader 的 baseUrl / 网页原文地址），
   * 其余外链交给系统浏览器，避免在阅读视图里原地跳走。
   * 注意：将来支持内嵌媒体（iframe 白名单）时，这里要放行白名单域。
   */
  private handleLinkIntercept(url: string): boolean {
    if (url.length === 0 || url.startsWith('about:') || url.startsWith('data:') || url.startsWith('file:')) {
      return false;
    }
    const article: Article = this.cur();
    if (article.link.length > 0 && url.startsWith(article.link)) {
      return false;
    }
    this.openInBrowserUrl(url);
    return true;
  }

  private openInBrowserUrl(url: string): void {
    articleActions.openInBrowser(this.hostContext(), url).then((ok: boolean) => {
      if (!ok) {
        this.toast($r('app.string.toast_action_failed'));
      }
    });
  }

  private async copyLink(article: Article): Promise<void> {
    const ok: boolean = await articleActions.copyText(article.link.length > 0 ? article.link : article.title);
    if (ok) {
      this.snack($r('app.string.snack_link_copied'));
    } else {
      this.toast($r('app.string.toast_action_failed'));
    }
  }

  /**
   * 只看该源：把首页列表收敛到这篇文章的来源，并退回首页（范围 chip 显示在首页顶部，可一键清除）。
   * 源已被删时提示且不动作。
   */
  private scopeToThisFeed(article: Article): void {
    if (!feedViewModel.scopeToFeedById(article.feedId)) {
      this.toast($r('app.string.toast_action_failed'));
      return;
    }
    this.navPathStack.popToIndex(0);
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

  /**
   * 设置阅读模式并记住选择（只在用户手动切换时调用）。
   * 自动回退（如正文提取失败退网页）不写偏好，否则用户下次进来会被迫停在原文模式。
   */
  private applyViewMode(mode: string): void {
    this.viewMode = mode;
    appSettings.readerViewMode = mode;
    settingsStore.save();
  }

  // ---- 正文标注（高亮 + 备注） ----

  /** 读出当前文章的标注并重放到正文里。 */
  private async loadHighlights(): Promise<void> {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined) {
      this.highlights = [];
      return;
    }
    this.highlights = await articleStore.listHighlights(article.id);
    this.highlights = await articleStore.listHighlights(article.id);
    this.replayHighlights(this.activeController());
  }

  /** 当前模式的 Web 控制器（正文注入都走它）。 */
  private activeController(): webview.WebviewController {
    return this.viewMode === MODE_WEB ? this.webController : this.readerController;
  }

  /**
   * 把标注重放进文档：先注入支持脚本（幂等），再 apply 一次。
   * 注入失败只表现为没有高亮，不影响阅读（站点 CSP 场景）。
   */
  private replayHighlights(controller: webview.WebviewController): void {
    const items: HighlightItem[] = [];
    for (let i = 0; i < this.highlights.length; i += 1) {
      const h: Highlight = this.highlights[i];
      items.push(new HighlightItem(h.id, h.quote, h.color, h.note.length > 0));
    }
    try {
      controller.runJavaScript(highlightSupportScript())
        .then(() => controller.runJavaScript(applyHighlightsScript(items)))
        .catch((err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'highlight inject failed: %{public}d', err.code);
        });
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'highlight inject threw: %{public}d', error.code);
    }
  }

  /**
   * 把当前选段存成标注。
   * anchor_ratio 由文档侧算（选区起点在文中的比例）——引文以后定位不到时用它兜底跳转。
   */
  private addHighlight(): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    const quote: string = this.selectedText.trim();
    if (article === undefined || quote.length === 0) {
      return;
    }
    const controller: webview.WebviewController = this.activeController();
    controller.runJavaScript(selectionRatioScript()).then((raw: string) => {
      const ratio: number = this.parseRatio(raw);
      const item: Highlight = new Highlight(this.newHighlightId(article.id), article.id, quote, '',
        HighlightColor.YELLOW, Date.now(), '', ratio);
      articleStore.addHighlight(item);
      this.selectedText = '';
      this.loadHighlights();
      this.snack($r('app.string.snack_highlight_added'));
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'add highlight failed: %{public}d', err.code);
    });
  }

  /** runJavaScript 回传可能被 JSON 序列化成带引号的字符串，这里统一剥掉再解析。 */
  private parseRatio(raw: string): number {
    const cleaned: string = raw.replace(/"/g, '');
    const value: number = Number.parseFloat(cleaned);
    if (Number.isNaN(value)) {
      return 0;
    }
    return Math.min(1, Math.max(0, value));
  }

  private newHighlightId(articleId: string): string {
    return articleId + '#' + Date.now().toString();
  }

  /** 打开标注编辑面板（文档内点标记走这里）。 */
  private openHighlightEditor(id: string): void {
    const item: Highlight | undefined = this.findHighlight(id);
    if (item === undefined) {
      return;
    }
    this.editingHighlightId = id;
    this.noteDraft = item.note;
    this.openSheet('hlEdit');
  }

  private findHighlight(id: string): Highlight | undefined {
    for (let i = 0; i < this.highlights.length; i += 1) {
      if (this.highlights[i].id === id) {
        return this.highlights[i];
      }
    }
    return undefined;
  }

  /** 保存备注（空串表示清除备注）。 */
  private saveHighlightNote(): void {
    const item: Highlight | undefined = this.findHighlight(this.editingHighlightId);
    if (item === undefined) {
      return;
    }
    item.note = this.noteDraft.trim();
    articleStore.updateHighlightNote(item.id, item.note);
    this.editingHighlightId = '';
    this.replayHighlights(this.activeController());
  }

  /** 改配色（就地改 + 重新重放，标记颜色立即更新）。 */
  private setHighlightColor(id: string, color: string): void {
    const item: Highlight | undefined = this.findHighlight(id);
    if (item === undefined) {
      return;
    }
    item.color = color;
    articleStore.updateHighlightColor(id, color);
    this.replayHighlights(this.activeController());
  }

  /** 删除标注。 */
  private removeHighlight(id: string): void {
    articleStore.deleteHighlight(id);
    this.editingHighlightId = '';
    this.loadHighlights();
    this.snack($r('app.string.snack_highlight_removed'));
  }

  /** 跳到某条标注；引文定位失败时按 anchor_ratio 兜底。 */
  private gotoHighlight(item: Highlight): void {
    const controller: webview.WebviewController = this.activeController();
    const fallback: string = gotoRatioScript(item.anchorRatio);
    controller.runJavaScript(gotoHighlightScript(item.id)).then((raw: string) => {
      // 回传 "true"/"false"（可能带引号）
      if (raw.replace(/"/g, '') !== 'true') {
        controller.runJavaScript(fallback);
      }
    }).catch(() => {
      controller.runJavaScript(fallback);
    });
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
      this.applyViewMode(MODE_WEB);
      this.loading = true;
    } else {
      this.applyViewMode(MODE_READER);
      this.startReader();
    }
  }

  /**
   * 原地切换到上一篇 / 下一篇 / 下一条未读（不重新 push 路由）。
   * slideFrom：1 = 新内容从右侧滑入（下一篇），-1 = 从左侧滑入（上一篇）。
   */
  private openRelative(id: string, slideFrom: number = 1): void {
    if (id.length === 0) {
      return;
    }
    feedViewModel.openArticle(id);
    // 不重置 readerHtml：保持 Reader Web 挂载，随后直接换文档，避免 controller 失效。
    this.progressRatio = 0;
    // 换了文章：停掉朗读
    if (this.speaking) {
      readerSpeech.stop();
    }
    // 沉浸态与查找条都复位（新文章从完整界面开始）
    if (this.barsHidden) {
      this.barsHidden = false;
      this.onImmersiveChange(false);
    }
    this.findOpen = false;
    this.findQuery = '';
    this.findCount = 0;
    this.findIndex = 0;
    this.readerFailed = false;
    this.webProgressRestored = false;
    this.readerProgressRestored = false;
    this.finished = false;
    this.loading = true;
    if (this.viewMode === MODE_READER) {
      this.startReader();
    }
    // 网页原文模式：Web 的 src 随 article.link 变化自动重载，等 onPageEnd 收尾。
    this.playSwitchAnimation(slideFrom);
    this.loadHighlights();
  }

  /**
   * 切文动效：先把正文按方向推开一点，再动画回位。
   * 不做书页翻转 —— 正文是 Web 文档，换文档本身开销已经不小，这里只做轻量位移 + 淡入。
   */
  private playSwitchAnimation(slideFrom: number): void {
    this.bodyShift = slideFrom * 24;
    this.bodyAlpha = 0.35;
    this.getUIContext().animateTo({ duration: 180, curve: Curve.Friction }, () => {
      this.bodyShift = 0;
      this.bodyAlpha = 1;
    });
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
    // 起手点必须在屏幕中间带：贴左右边缘的滑动优先交给系统返回手势，避免互相抢。
    if (this.panStartX >= 0 && !this.isMiddleBand(this.panStartX)) {
      return;
    }
    if (deltaX < 0) {
      this.openRelative(feedViewModel.nextArticleId(), 1);
    } else {
      this.openRelative(feedViewModel.prevArticleId(), -1);
    }
  }

  /** 起手点是否落在屏幕中间 60%（px，与 globalX 同坐标系）。 */
  private isMiddleBand(globalX: number): boolean {
    try {
      const width: number = display.getDefaultDisplaySync().width;
      return globalX > width * 0.2 && globalX < width * 0.8;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'display info failed: %{public}d', error.code);
      return true;
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
        content: this.speaking ? $r('app.string.action_stop_speech') : $r('app.string.action_start_speech'),
        symbolStartIcon: this.menuIcon(this.speaking ? $r('sys.symbol.stop_circle') : $r('sys.symbol.speaker'))
      })
        .onClick(() => {
          this.toggleSpeech();
        })
      MenuItem({
        content: $r('app.string.action_find_in_article'),
        symbolStartIcon: this.menuIcon($r('sys.symbol.magnifyingglass'))
      })
        .onClick(() => {
          this.openFind();
        })
      MenuItem({
        content: $r('app.string.action_copy_body'),
        symbolStartIcon: this.menuIcon($r('sys.symbol.text_clipboard'))
      })
        .onClick(() => {
          this.copyBody();
        })
      MenuItem({
        content: $r('app.string.action_share_body'),
        symbolStartIcon: this.menuIcon($r('sys.symbol.share'))
      })
        .onClick(() => {
          this.shareBody();
        })
      MenuItem({
        content: $r('app.string.action_copy_link'),
        symbolStartIcon: this.menuIcon($r('sys.symbol.link'))
      })
        .onClick(() => {
          this.copyLink(article);
        })
      MenuItem({
        content: $r('app.string.hl_panel_entry'),
        symbolStartIcon: this.menuIcon($r('sys.symbol.paintpalette'))
      })
        .onClick(() => {
          this.openSheet('hlList');
        })
      MenuItem({
        content: $r('app.string.action_scope_feed'),
        symbolStartIcon: this.menuIcon($r('sys.symbol.folder'))
      })
        .onClick(() => {
          this.scopeToThisFeed(article);
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

  aboutToAppear(): void {
    // 恢复上次用的阅读模式：上次停在「网页原文」时直接进 Web，
    // 不能再跑一遍 startReader()（它会无条件把 viewMode 拽回阅读器）。
    const article: Article | undefined = feedViewModel.currentArticle();
    if (appSettings.readerViewMode === MODE_WEB && article !== undefined && article.link.length > 0) {
      this.viewMode = MODE_WEB;
      this.loading = true;
    } else {
      this.viewMode = MODE_READER;
      this.startReader();
    }
    this.loadHighlights();
    if (appSettings.readerKeepScreenOn) {
      screenAwake.set(true, this.getUIContext().getHostContext());
    }
  }

  /** 离开详情页：恢复系统息屏策略，并按当前模式取一次滚动位置写回。 */
  aboutToDisappear(): void {
    screenAwake.set(false, this.getUIContext().getHostContext());
    readerSpeech.release();
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
    if (article === undefined || (article.progress <= 0 && article.progressRatio <= 0)) {
      return;
    }
    this.runRestore(controller, new ReaderPosition(article.progress, article.progressRatio));
  }

  /**
   * 落回指定位置：比例优先（换排版后 px 会漂），px 仅作老数据兜底。
   * 脚本自带重试 —— 文档可能还在长高，一次性滚动会被顶掉。
   */
  private runRestore(controller: webview.WebviewController, position: ReaderPosition): void {
    controller
      .runJavaScript(restorePositionScript(position.ratio, position.y))
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'restore progress failed: %{public}d', err.code);
      });
  }

  /** 注入滚动监听与点按监听（进度条 + 沉浸切换用；失败不影响阅读）。 */
  private bindProgressListener(controller: webview.WebviewController): void {
    controller
      .runJavaScript(progressListenerScript())
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'progress listener failed: %{public}d', err.code);
      });
  }

  /**
   * 正文触摸判定：短按、几乎没位移、且落在屏幕中间 60% 区域 → 视为「点按中部」。
   * 放在 ArkTS 侧而不是注入脚本：ArkWeb 里 text 区域的合成点按不一定抛出 DOM click 事件（实测点按回调收不到）。
   */
  private handleBodyTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      if (event.touches.length > 0) {
        this.tapStartX = event.touches[0].windowX;
        this.tapStartY = event.touches[0].windowY;
        this.tapStartTime = Date.now();
      }
      return;
    }
    if (event.type !== TouchType.Up || this.tapStartTime === 0) {
      return;
    }
    const startX: number = this.tapStartX;
    const startY: number = this.tapStartY;
    const moved: number = event.changedTouches.length > 0
      ? Math.abs(event.changedTouches[0].windowX - startX) + Math.abs(event.changedTouches[0].windowY - startY)
      : 0;
    const elapsed: number = Date.now() - this.tapStartTime;
    this.tapStartTime = 0;
    if (elapsed > 300 || moved > 12) {
      return;
    }
    if (this.isMiddleBandVp(startY)) {
      this.toggleBars();
    }
  }

  /** 竖直方向是否落在屏幕中间 60%（入参是 vp）。 */
  private isMiddleBandVp(windowY: number): boolean {
    try {
      const heightVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().height);
      return windowY > heightVp * 0.25 && windowY < heightVp * 0.75;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'display info failed: %{public}d', error.code);
      return false;
    }
  }

  /** 沉浸阅读：点按正文中部时切换标题栏与底栏显隐。 */
  private toggleBars(): void {
    this.barsHidden = !this.barsHidden;
    this.onImmersiveChange(this.barsHidden);
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

  /** 读一次文档位置（px + 比例）并写回本地库。 */
  private readScrollY(controller: webview.WebviewController, articleId: string): void {
    controller.runJavaScript(readPositionScript(), (err: BusinessError, value: string) => {
      if (err) {
        hilog.warn(DOMAIN, TAG, 'read scroll position failed: %{public}d', err.code);
        return;
      }
      const position: ReaderPosition = parsePosition(value);
      feedViewModel.saveProgress(articleId, position.y, position.ratio);
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
        this.openRelative(feedViewModel.prevArticleId(), -1);
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

  /** 底栏操作：阅读排版（打开半模态面板：字号/行距连续可调 + 栏宽/对齐/主题/字体）。 */
  @Builder
  FontAction() {
    SymbolGlyph($r('sys.symbol.textformat'))
      .fontSize($r('app.float.icon_size'))
      .fontColor([$r('sys.color.font_primary')])
      .padding($r('app.float.space_xs'))
      .accessibilityText($r('app.string.row_reader_font'))
      .onClick(() => {
        this.openSheet('read');
      })
  }

  /** 打开半模态并指定内容类型（'' 之外都要走这里，保证显隐与内容同步）。 */
  private openSheet(mode: string): void {
    this.sheetMode = mode;
    this.showSheet = true;
  }

  /** 关闭半模态（面板内的动作触发的关闭）。 */
  private closeSheet(): void {
    this.showSheet = false;
    this.sheetMode = '';
  }

  /** 半模态内容分派：同一时刻只有一种（见 sheetMode 的说明）。 */
  @Builder
  SheetContent() {
    if (this.sheetMode === 'hlList') {
      this.HighlightPanel()
    } else if (this.sheetMode === 'hlEdit') {
      this.HighlightEditor()
    } else {
      this.ReadSheet()
    }
  }

  /** 标注面板：列出本文全部标注，点一条跳过去，右侧「改色 / 备注 / 删除」。 */
  @Builder
  HighlightPanel() {
    Column({ space: $r('app.float.space_m') }) {
      Text($r('app.string.hl_panel_title', this.highlights.length))
        .fontSize($r('app.float.font_size_section'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      if (this.highlights.length === 0) {
        Text($r('app.string.hl_panel_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      } else {
        // List 的 space 只收 string|number，不接受资源引用：间距放在条目 margin 上。
        List() {
          ForEach(this.highlights, (item: Highlight) => {
            ListItem() {
              Column({ space: $r('app.float.space_xs') }) {
                Row({ space: $r('app.float.space_s') }) {
                  // 配色圆点
                  Row()
                    .width($r('app.float.feed_dot_size'))
                    .height($r('app.float.feed_dot_size'))
                    .backgroundColor(this.colorOf(item.color))
                    .borderRadius($r('app.float.feed_dot_size'))
                  Text(item.quote)
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor($r('app.color.hm_text_primary'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')

                if (item.note.length > 0) {
                  Text(item.note)
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor($r('app.color.hm_text_secondary'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }

                Row({ space: $r('app.float.space_m') }) {
                  Text($r('app.string.hl_action_goto'))
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor($r('app.color.hm_brand'))
                    .onClick(() => {
                      this.closeSheet();
                      this.gotoHighlight(item);
                    })
                  Text($r('app.string.hl_action_note'))
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor($r('app.color.hm_brand'))
                    .onClick(() => {
                      this.openHighlightEditor(item.id);
                    })
                  Text($r('app.string.hl_action_color'))
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor($r('app.color.hm_brand'))
                    .onClick(() => {
                      this.setHighlightColor(item.id, this.nextColor(item.color));
                    })
                  Text($r('app.string.action_delete'))
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor($r('app.color.hm_danger'))
                    .onClick(() => {
                      this.removeHighlight(item.id);
                    })
                }
                .width('100%')
              }
              .width('100%')
              .padding($r('app.float.space_m'))
              .backgroundColor($r('app.color.hm_card_background'))
              .borderRadius($r('app.float.radius_card'))
              .alignItems(HorizontalAlign.Start)
            }
            .margin({ bottom: $r('app.float.space_s') })
          }, (item: Highlight) => item.id)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding($r('app.float.space_l'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 标注编辑面板：备注输入 + 配色 + 删除（点正文里的标记也会打开它）。 */
  @Builder
  HighlightEditor() {
    Column({ space: $r('app.float.space_m') }) {
      Text($r('app.string.hl_editor_title'))
        .fontSize($r('app.float.font_size_section'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      Text(this.editingQuote())
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding($r('app.float.space_m'))
        .backgroundColor($r('app.color.hm_value_chip_background'))
        .borderRadius($r('app.float.radius_menu_item'))

      TextInput({ text: this.noteDraft, placeholder: $r('app.string.hl_note_hint') })
        .type(InputType.Normal)
        .fontSize($r('app.float.font_size_body'))
        .width('100%')
        .onChange((value: string) => {
          this.noteDraft = value;
        })

      Row({ space: $r('app.float.space_m') }) {
        ForEach(this.colorOptions(), (color: string) => {
          Row()
            .width($r('app.float.hl_color_size'))
            .height($r('app.float.hl_color_size'))
            .backgroundColor(this.colorOf(color))
            .borderRadius($r('app.float.feed_dot_size'))
            .borderWidth(2)
            .borderColor(this.editingColor() === color
              ? $r('app.color.hm_text_primary')
              : $r('app.color.hm_page_transparent'))
            .onClick(() => {
              this.setHighlightColor(this.editingHighlightId, color);
            })
        }, (color: string) => color)
      }
      .width('100%')

      Row({ space: $r('app.float.space_m') }) {
        Button($r('app.string.action_delete'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .onClick(() => {
            this.removeHighlight(this.editingHighlightId);
          })
        Blank()
        Button($r('app.string.dialog_confirm'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .onClick(() => {
            this.saveHighlightNote();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_l'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 配色语义 id → 实际色值。 */
  private colorOf(color: string): ResourceColor {
    if (color === HighlightColor.GREEN) {
      return $r('app.color.hl_green');
    }
    if (color === HighlightColor.BLUE) {
      return $r('app.color.hl_blue');
    }
    if (color === HighlightColor.PINK) {
      return $r('app.color.hl_pink');
    }
    return $r('app.color.hl_yellow');
  }

  /** 可选的四种配色。 */
  private colorOptions(): string[] {
    return [HighlightColor.YELLOW, HighlightColor.GREEN, HighlightColor.BLUE, HighlightColor.PINK];
  }

  /** 轮换到下一种配色（面板里快速改色用）。 */
  private nextColor(current: string): string {
    const options: string[] = this.colorOptions();
    const index: number = options.indexOf(current);
    return options[(index + 1) % options.length];
  }

  private editingQuote(): string {
    const item: Highlight | undefined = this.findHighlight(this.editingHighlightId);
    return item === undefined ? '' : item.quote;
  }

  private editingColor(): string {
    const item: Highlight | undefined = this.findHighlight(this.editingHighlightId);
    return item === undefined ? '' : item.color;
  }

  /** 排版面板内容（半模态：沉浸光感生效区域，材质由 bindSheet 的 options 注入）。 */
  @Builder
  ReadSheet() {
    ReadSettingsSheet({
      webMode: this.viewMode === MODE_WEB,
      onApply: () => {
        this.applyTypography();
      }
    })
  }

  /**
   * 应用排版改动：Reader 模式重建文档（先记住当前滚动位置，重建完在 onPageEnd 落回），
   * 网页原文模式只需重新注入覆盖样式（幂等）。
   */
  private applyTypography(): void {
    if (this.viewMode === MODE_READER && this.readerHtml.length > 0) {
      const controller: webview.WebviewController = this.readerController;
      controller.runJavaScript(readPositionScript(), (err: BusinessError, value: string) => {
        if (!err) {
          this.pendingRestore = parsePosition(value);
        }
        this.loadReaderDocIntoWeb();
      });
      return;
    }
    if (this.viewMode === MODE_WEB) {
      readerStyle.apply(this.webController);
    }
  }

  /** 底栏操作：溢出菜单（重新提取 / 复制链接 / 浏览器打开 / 分享）。 */
  @Builder
  MoreAction() {
    SymbolGlyph($r('sys.symbol.more'))
      .fontSize($r('app.float.icon_size'))
      .fontColor([$r('sys.color.font_primary')])
      .padding($r('app.float.space_xs'))
      .accessibilityText($r('app.string.action_more'))
      .bindMenu(this.ActionsMenu(this.cur()), MaterialController.menuOptions({}, appSettings.immersiveOn))
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
            // 文档内滚动回调：window.hrProgress.onProgress(ratio)
            .javaScriptProxy({
              object: this.progressBridge,
              name: 'hrProgress',
              methodList: ['onProgress'],
              controller: this.readerController
            })
            // 文档内点标注：window.__hrHlCb.onHlClick(id)
            .javaScriptProxy({
              object: this.hlBridge,
              name: '__hrHlCb',
              methodList: ['onHlClick'],
              controller: this.readerController
            })
            .onLoadIntercept((event: OnLoadInterceptEvent) => {
              return this.handleLinkIntercept(event.data.getRequestUrl());
            })
            .onTextSelectionChange((selectionText: string) => {
              this.selectedText = selectionText;
            })
            // 沉浸阅读：点按正文中部切换上下栏（ArkWeb 里 DOM click 不一定触发，改在 ArkTS 侧判定）
            .onTouch((event: TouchEvent) => {
              this.handleBodyTouch(event);
            })
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
              this.bindProgressListener(this.readerController);
              this.replayHighlights(this.readerController);
              const pending: ReaderPosition | undefined = this.pendingRestore;
              if (pending !== undefined) {
                // 排版变化导致的重建：落回改动前的阅读位置，避免「调字号跳回顶部」。
                this.pendingRestore = undefined;
                this.runRestore(this.readerController, pending);
              } else {
                this.restoreReaderProgress();
              }
            })
            .onOverScroll((event: OnOverScrollEvent) => {
              if (Math.abs(event.yOffset) >= OVERSCROLL_TRIGGER_VP) {
                this.checkReachedBottom(this.readerController);
              }
            })
            // 横向滑动切文：priorityGesture + IgnoreInternal 才能抢在 ArkWeb 内部手势之前。
            .priorityGesture(
              PanGesture({ direction: PanDirection.Horizontal, distance: SWIPE_DISTANCE_VP })
                .onActionStart((event: GestureEvent) => {
                  this.panStartX = event.fingerList.length > 0 ? event.fingerList[0].globalX : -1;
                })
                .onActionEnd((event: GestureEvent) => {
                  this.onHorizontalPan(event.offsetX);
                }),
              GestureMask.IgnoreInternal
            )
        } else {
          // 无正文可读（提取失败且无链接）：退纯文本。
          this.TextBody()
        }

        if (this.loading) {
          this.LoadingVeil()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.hm_web_surface'))
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
          // 文档内滚动回调：window.hrProgress.onProgress(ratio)
          .javaScriptProxy({
            object: this.progressBridge,
            name: 'hrProgress',
            methodList: ['onProgress'],
            controller: this.webController
          })
          // 文档内点标注：window.__hrHlCb.onHlClick(id)
          .javaScriptProxy({
            object: this.hlBridge,
            name: '__hrHlCb',
            methodList: ['onHlClick'],
            controller: this.webController
          })
          .onLoadIntercept((event: OnLoadInterceptEvent) => {
            return this.handleLinkIntercept(event.data.getRequestUrl());
          })
          .onTextSelectionChange((selectionText: string) => {
            this.selectedText = selectionText;
          })
          // 沉浸阅读：点按正文中部切换上下栏（ArkWeb 里 DOM click 不一定触发，改在 ArkTS 侧判定）
          .onTouch((event: TouchEvent) => {
            this.handleBodyTouch(event);
          })
          .onPageEnd(() => {
            this.loading = false;
            // 网页原文的排版只能靠注入：按设置覆盖正文字号 / 行距 / 字体族。
            readerStyle.apply(this.webController);
            this.bindProgressListener(this.webController);
            this.replayHighlights(this.webController);
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
              .onActionStart((event: GestureEvent) => {
                this.panStartX = event.fingerList.length > 0 ? event.fingerList[0].globalX : -1;
              })
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
      .backgroundColor($r('app.color.hm_web_surface'))
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
            .fontSize(ReaderTypography.fontSizePx(appSettings.readerFontScale))
            .lineHeight(ReaderTypography.fontSizePx(appSettings.readerFontScale)
              * ReaderTypography.lineHeightOf(appSettings.readerLineScale))
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

  /** 文内查找条：贴标题栏下方，输入即查、可上/下跳转。 */
  @Builder
  FindBar() {
    if (this.findOpen) {
      Row({ space: $r('app.float.space_s') }) {
        TextInput({ text: this.findQuery, placeholder: $r('app.string.find_hint') })
          .type(InputType.Normal)
          .fontSize($r('app.float.font_size_caption'))
          .layoutWeight(1)
          .onChange((value: string) => {
            this.applyFind(value);
          })

        Text(this.findCount > 0
          ? $r('app.string.find_count', this.findIndex + 1, this.findCount)
          : $r('app.string.find_none'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)

        SymbolGlyph($r('sys.symbol.chevron_up'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([this.findCount > 0 ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
          .enabled(this.findCount > 0)
          .onClick(() => {
            this.stepFind(-1);
          })

        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([this.findCount > 0 ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
          .enabled(this.findCount > 0)
          .onClick(() => {
            this.stepFind(1);
          })

        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .onClick(() => {
            this.closeFind();
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.space_l'),
        right: $r('app.float.space_l'),
        top: $r('app.float.space_s'),
        bottom: $r('app.float.space_s')
      })
      .margin({ left: $r('app.float.space_l'), right: $r('app.float.space_l'), top: $r('app.float.space_s') })
      .backgroundColor($r('app.color.hm_card_background'))
      .borderRadius($r('app.float.radius_card'))
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 朗读迷你条：朗读中出现在底栏上方，可停止。 */
  @Builder
  SpeechBar() {
    if (this.speaking) {
      Row({ space: $r('app.float.space_s') }) {
        SymbolGlyph($r('sys.symbol.speaker'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([$r('app.color.hm_brand')])

        Text($r('app.string.speech_running'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Button($r('app.string.action_stop_speech'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .onClick(() => {
            readerSpeech.stop();
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.space_l'),
        right: $r('app.float.space_m'),
        top: $r('app.float.space_s'),
        bottom: $r('app.float.space_s')
      })
      .margin({
        left: $r('app.float.space_l'),
        right: $r('app.float.space_l'),
        bottom: $r('app.float.space_s')
      })
      .backgroundColor($r('app.color.hm_card_background'))
      .borderRadius($r('app.float.radius_card'))
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 选段浮条：选中正文后出现，提供复制 / 分享选段。 */
  @Builder
  SelectionBar() {
    if (this.selectedText.length > 0) {
      Row({ space: $r('app.float.space_s') }) {
        Text(this.selectionPreview())
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Button($r('app.string.action_highlight'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .onClick(() => {
            this.addHighlight();
          })

        Button($r('app.string.action_copy'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .onClick(() => {
            this.copySelection();
          })

        Button($r('app.string.action_share_selection'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .onClick(() => {
            this.shareSelection();
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.space_l'),
        right: $r('app.float.space_m'),
        top: $r('app.float.space_s'),
        bottom: $r('app.float.space_s')
      })
      .margin({
        left: $r('app.float.space_l'),
        right: $r('app.float.space_l'),
        bottom: $r('app.float.selection_bar_gap')
      })
      .backgroundColor($r('app.color.hm_card_background'))
      .borderRadius($r('app.float.radius_card'))
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 选中文本预览（压缩空白 + 截断）。 */
  private selectionPreview(): string {
    const flat: string = this.selectedText.replace(/\s+/g, ' ').trim();
    return flat.length > 40 ? flat.substring(0, 40) + '…' : flat;
  }

  /** 标题栏下沿的细进度条：只在正文模式显示，随文档滚动刷新。 */
  @Builder
  ProgressLine() {
    if (this.hasArticle() && this.progressRatio > 0.001) {
      Row() {
        Row()
          .width(Math.round(this.progressRatio * 100) + '%')
          .height($r('app.float.read_progress_height'))
          .backgroundColor($r('app.color.hm_brand'))
          .borderRadius($r('app.float.read_progress_height'))
      }
      .width('100%')
      .height($r('app.float.read_progress_height'))
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 正文铺满整页（含标题栏与悬浮底栏下方），从两栏下方穿过 —— 与首页 barOverlap(true) 同源；
      // 首尾让位由正文自己留：Reader 文档 / 网页原文走 CSS 内边距，纯文本走滚动内容里的占位与底部内边距。
      // 切文时由 playSwitchAnimation 给一层轻量位移 + 淡入。
      Column() {
        this.BodySwitch()
      }
      .width('100%')
      .height('100%')
      .translate({ x: this.bodyShift })
      .opacity(this.bodyAlpha)

      // 底栏：沉浸态下收起（高度 + 透明度动画；内容底部预留是固定的，收起后只是多点留白）
      Column() {
        this.FloatingBar()
      }
      .width('100%')
      .height(this.barsHidden ? 0 : this.barStripHeight())
      .opacity(this.barsHidden ? 0 : 1)
      .clip(true)
      .animation({ duration: 180, curve: Curve.Friction })

      // 底部浮层：朗读条 + 选段条（都贴在底栏上方）
      Column() {
        Blank()
        this.SpeechBar()
        this.SelectionBar()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.Center)
      .hitTestBehavior(HitTestMode.Transparent)

      // 查找条层：贴标题栏下方（只占自身高度，不挡正文滚动）
      Column() {
        Row()
          .width('100%')
          .height(safeArea.contentTopInsetVp)
        this.FindBar()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)

      // 进度条层：铺满整页、内容贴顶，但不吃手势（正文滚动 / 点按照常）。
      Column() {
        Row()
          .width('100%')
          .height(safeArea.contentTopInsetVp)
        this.ProgressLine()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.hm_page_transparent'))
    .bindSheet(this.showSheet, this.SheetContent(), MaterialController.sheetOptions({
      height: this.sheetMode === 'read' ? SheetSize.LARGE : SheetSize.MEDIUM,
      dragBar: true,
      onDisappear: () => {
        this.showSheet = false;
        this.sheetMode = '';
      }
    }, appSettings.immersiveOn))
  }
}
