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
import { display } from '@kit.ArkUI';
import { KeyCode } from '@kit.InputKit';
import { Article } from '../model/Feed';
import { GroupSource } from '../model/Dedupe';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { safeArea } from '../service/SafeAreaController';
import { NetworkStatus } from '../service/NetworkStatus';
import { MaterialController } from '../service/MaterialController';
import { CommonConstants } from '../common/constants/CommonConstants';
import { articleActions } from '../service/ArticleActions';
import { settingsViewModel } from '../viewmodel/SettingsViewModel';
import { ReadSettingsSheet } from './ReadSettingsSheet';
import { Toast } from '@monkey0803/toast-kit';
import { Keyboard } from '@monkey0803/keyboard-kit';
import { toPlainText } from '../common/utils/HtmlText';
import { UrlText } from '../common/utils/UrlText';
import { ArticleLinkTarget, articleLinkTarget, isWebLink } from '../service/LinkNavigation';
import { screenAwake } from '../service/ScreenAwake';
import { readerSpeech, SpeechProgress, SpeechStatus } from '../service/ReaderSpeech';
import { speechLanguageOf } from '../service/ReaderSpeechLanguage';
import {
  clearSpeechSegmentScript,
  collectSpeechSegmentsScript,
  markSpeechSegmentScript,
  parseSpeechSegments,
  ReaderSpeechScrollBridge,
  speechManualScrollScript,
  SpeechSegment
} from '../service/ReaderSpeechDocument';
import {
  clearFindScript,
  countFindScript,
  findSupportScript,
  gotoFindScript,
  runFindScript
} from '../service/ReaderFind';
import { readerStyle } from '../service/ReaderStyle';
import { ReaderNeedsJsError, ReaderPlaceholderError } from '../service/ReaderContentGuard';
import { TocEntry, collectTocScript, gotoHeadingScript } from '../service/ReaderToc';
import { imageAtPointScript } from '../service/ReaderImage';
import { readerImageSave } from '../service/ReaderImageSave';
import { ReaderImageViewer } from './ReaderImageViewer';
import { ReaderBodyView } from './reader/ReaderBodyView';
import { ReaderProgressQueue } from '../service/ReaderProgressQueue';
import { WebBodyView } from './reader/WebBodyView';
import { ArticleActionBar } from './reader/ArticleActionBar';
import {
  ReadSheetView,
  ShareSheetView,
  SourcesPanelView,
  TagSheetView,
  TocSheetView,
  TranslateSheetView
} from './reader/DetailSheets';
import { settingsStore } from '../service/SettingsStore';
import { ReaderViewMode } from '../common/constants/RssConstants';
import { buildReaderDocument, readerStyleScript } from '../service/ReaderDocument';
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
import { highlightStore, articleRepository } from '../service/ArticleServices';
import { readingContinuation } from '../service/ReadingContinuation';
import {
  parsePosition,
  positionFromMetrics,
  progressObserverScript,
  ReaderPosition,
  ReaderProgressBridge,
  readPositionScript,
  restorePositionScript
} from '../service/ReaderProgress';
import { appSettings } from '../model/AppSettings';
import { ReaderTypography } from '../common/constants/SettingsConstants';
import { TagWithCount } from '../model/Tag';
import { tagViewModel } from '../viewmodel/TagViewModel';
import { TagPickerSheet } from './TagPickerSheet';
import { ShareSheet } from './ShareSheet';
import { ShareContext } from '../model/Share';
import { shareService } from '../service/ShareService';
import { shareViewModel } from '../viewmodel/ShareViewModel';
import { translationViewModel } from '../viewmodel/TranslationViewModel';
import { TranslateSheet } from './TranslateSheet';
import { RouterConstants } from '../common/constants/RouterConstants';
import { Enclosure, firstAudio, firstVideo, formatDuration } from '../model/Enclosure';
import {
  MEDIA_ERROR,
  MEDIA_IDLE,
  MEDIA_LOADING,
  MEDIA_PLAYING,
  mediaPlayerService
} from '../service/MediaPlayerService';
import { AppMenu } from '../common/components/AppMenu';
import { AppSheet } from '../common/components/AppSheet';
import { MenuItemSpec, MenuSpec } from '../common/components/MenuSpec';
import { themePalette } from '../model/ThemePalette';
import { ClearInputButton } from '../common/components/ClearInputButton';

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
/** 正文纯文本短于这个字符数时，认为可能只取到了摘要，给一个「网页原文」提示入口。 */
const SHORT_BODY_HINT_CHARS: number = 500;
/** 标题下方标签条的固定高度（vp）：正文整体下移同样高度，chips 才不会压住首行文字。 */
const TAG_STRIP_VP: number = 44;
/** 底部双行查找面板：40vp 输入行 + 40vp 操作行 + 4vp 行距 + 16vp 上下内边距。 */
const FIND_BAR_HEIGHT_VP: number = 100;
const FIND_CONTROL_HEIGHT_VP: number = 40;

/** 网页原文渲染后抓快照的延迟（毫秒）：等首屏排版 / 懒加载图片稳定后再取 DOM。 */
const WEB_SNAPSHOT_DELAY_MS: number = 1800;

/**
 * 解出 runJavaScript 回传的字符串。
 * ArkWeb 可能把结果 JSON 序列化一次（甚至两次），这里最多剥两层引号包裹再返回。
 */
function decodeJsResultString(raw: string): string {
  let value: string = raw;
  for (let i = 0; i < 2; i += 1) {
    const trimmed: string = value.trim();
    if (trimmed.length === 0 || trimmed.charAt(0) !== '"') {
      break;
    }
    try {
      const parsed: string = JSON.parse(trimmed) as string;
      if (typeof parsed !== 'string') {
        break;
      }
      value = parsed;
    } catch (err) {
      break;
    }
  }
  return value;
}

/** 目录采集脚本回传的原始项（只读，逐字段校验后再转 TocEntry）。 */
interface TocRaw {
  level?: number;
  text?: string;
  index?: number;
}

/** 空文章占位：@Builder 内不能声明局部变量，用辅助方法返回兜底对象避免 undefined 判空。 */
const EMPTY_ARTICLE: Article = new Article('', '', '', '', '', '', '', 0);

@ComponentV2
export struct ArticleDetailView {
  /** 当前阅读模式。 */
  @Local viewMode: string = appSettings.readerViewMode;
  @Local loading: boolean = true;
  /** 网页原文主文档加载失败；子资源失败不遮住可读正文。 */
  @Local webFailed: boolean = false;
  /** 提取失败：可退网页原文 / 纯文本。 */
  @Local readerFailed: boolean = false;
  @Local offlineBusy: boolean = false;
  /** 已提取并净化好的正文片段（由 ViewModel 提供，命中本地缓存时无需联网）。 */
  @Local readerHtml: string = '';
  private readerController: webview.WebviewController = new webview.WebviewController();
  private webController: webview.WebviewController = new webview.WebviewController();
  private returnFromLinkedWeb: boolean = false;
  /** 提取正文模式的可滚动控制器（由外层 HdsNavDestination 绑定，用于标题栏材质随滚动跟手渐变 + 阅读进度）。 */
  @Param scroller: Scroller = new Scroller();
  /** 网页原文只在首次加载完成时恢复一次进度，避免页面内跳转后又被拉回去。 */
  private webProgressRestored: boolean = false;
  private readerProgressRestored: boolean = false;
  /** 已滑到文末：不再写回滚动进度，让下次打开从头开始。 */
  private finished: boolean = false;
  /** 触底检测在途标记（避免过度滚动事件重复触发 runJavaScript）。 */
  private bottomCheckPending: boolean = false;
  /** 网页原文渲染后的快照在途标记（SPA 站点：抓一次 DOM 存成离线正文）。 */
  private webSnapshotPending: boolean = false;
  /** 已经抓过快照的文章 id：同一篇只抓一次，避免翻页时反复执行脚本。 */
  private webSnapshotArticleId: string = '';
  /** 「阅读排版」半模态面板显隐。 */
  /**
   * 半模态面板当前显示哪一种内容：'' 关闭 / 'read' 阅读排版 / 'hlList' 标注列表 / 'hlEdit' 标注编辑 /
   * 'tags' 标签选择 / 'sources' 来源列表 / 'share' 统一分享面板。
   * 一个宿主（AppSheet）上只能挂一个半模态（挂多个只会生效最后一个），所以用一个状态切换内容。
   */
  @Local sheetMode: string = '';
  /** 半模态显隐（传给 AppSheet 的 visible）。 */
  @Local showSheet: boolean = false;
  /** 当前阅读进度（0–1），用于标题栏下方的细进度条；由文档内滚动回调刷新。 */
  @Local progressRatio: number = 0;
  /** 恢复位置时忽略脚本产生的中间滚动，避免把未恢复完成的位置写回。 */
  private progressReadyAt: number = 0;
  private progressQueue: ReaderProgressQueue = new ReaderProgressQueue(
    (articleId: string, position: ReaderPosition): void => {
      feedViewModel.saveProgress(articleId, position.y, position.ratio);
    },
    (): boolean => this.finished);
  private progressPollTimer: number = -1;
  private progressPollVersion: number = 0;
  private lastPolledY: number = -1;
  /** 上一次刷新进度条 UI 的时刻：滚动上报很密，进度条按 ~4 帧/秒节流，避免整页频繁重建。 */
  private progressRatioAt: number = 0;
  /** 本次文档是否已把标注注入过（净化文档里没有历史高亮时跳过注入，省两次 JS 往返）。 */
  private highlightInjected: boolean = false;
  /** 本次文档是否已收到过滚动上报（只打一条日志，便于确认桥接生效）。 */
  private progressBridgeSeen: boolean = false;
  /** 当前会话内分别记住 Reader 与网页原文的位置，切回原模式时不复用另一种排版的坐标。 */
  /** 正文里选中的文本（Web 的 onTextSelectionChange 回调）；非空时显示「复制/分享选段」浮条。 */
  @Local selectedText: string = '';
  /** 当前文章的标注（本地库读出；正文里靠注入脚本重放高亮）。 */
  @Local highlights: Highlight[] = [];
  /** 当前文章的标签（标题下方的 chips；由 TagViewModel 读出）。 */
  @Local articleTags: TagWithCount[] = [];
  /** 正文目录（h1–h4；打开「目录」时从文档里采集）。 */
  @Local toc: TocEntry[] = [];
  /** 图片查看器：当前图片地址与显隐。 */
  @Local viewerSrc: string = '';
  @Local viewerOpen: boolean = false;
  /** 当前文章所属合并组的全部来源（跨源去重；只有 >1 时才展示）。 */
  @Local groupSources: GroupSource[] = [];
  /** 正在编辑的标注（弹面板改备注 / 改色 / 删除）。 */
  @Local editingHighlightId: string = '';
  /** 备注输入草稿。 */
  @Local noteDraft: string = '';
  /** 切文动效：正文容器的临时位移/透明度（animateTo 收尾回 0 / 1）。 */
  @Local bodyShift: number = 0;
  @Local bodyAlpha: number = 1;
  /** 朗读：是否正在朗读（控制迷你播放条与菜单文案）。 */
  @Local speaking: boolean = false;
  /** 朗读：是否暂停（播放条显示「继续」）。 */
  @Local speechPaused: boolean = false;
  /** 朗读：当前块下标与总块数（长文分句后的进度）。 */
  @Local speechIndex: number = 0;
  @Local speechTotal: number = 0;
  /** 朗读：当前语速倍数。 */
  @Local speechSpeed: number = 1;
  /** 手动滚动后暂停自动跟随，播放条提供返回当前朗读段落的入口。 */
  @Local speechFollow: boolean = true;
  private speechSegmentId: number = -1;
  private speechScrollBridge: ReaderSpeechScrollBridge = new ReaderSpeechScrollBridge(() => {
    if (this.speaking && this.speechSegmentId >= 0) {
      this.speechFollow = false;
    }
  });
  /** 文档内滚动上报（hrProgress.onScroll）：正文进度、进度条与「滚动即已读」都由它驱动。 */
  private progressBridge: ReaderProgressBridge = new ReaderProgressBridge(
    (y: number, h: number, vh: number): void => {
      this.onProgressReported(y, h, vh);
    });
  /** 短正文提示是否已被用户关掉（切文时复位；提示本身按当前文章内容实时判断）。 */
  @Local shortBodyHintClosed: boolean = false;
  /** 横向手势的起手点（px），用于避让系统边缘返回手势。 */
  private panStartX: number = -1;
  /** 导航栈：「只看该源」要退回首页列表（范围 chip 在首页顶部）。 */
  @Param navPathStack: NavPathStack = new NavPathStack();
  /** 文内查找：查找条显隐、查询串、命中数与当前下标。 */
  @Local findOpen: boolean = false;
  @Local findQuery: string = '';
  @Local findCount: number = 0;
  @Local findIndex: number = 0;
  @Local findInputActivated: boolean = false;
  /** 当前文章纯文本缓存（复制正文 / 分享正文 / 朗读用）：按文章 id 失效。 */
  private plainTextCache: string = '';
  private plainTextCacheId: string = '';
  /** 文档内点标注 → ArkTS 弹编辑面板（javaScriptProxy，页面创建时注册一次）。 */
  private hlBridge: ReaderHighlightBridge = new ReaderHighlightBridge((id: string) => {
    this.openHighlightEditor(id);
  });
  /** 正文触摸判定（点按打开图片）：按下位置与时间。 */
  private tapStartX: number = -1;
  private tapStartY: number = -1;
  private tapStartTime: number = 0;
  /** 按下点在 Web 组件内的坐标（vp，≈ CSS px），用于图片命中测试。 */
  private tapLocalX: number = -1;
  private tapLocalY: number = -1;
  /** 预取下一篇正文的定时器（页面销毁 / 切文时清掉）。 */
  private prefetchTimer: number = -1;
  /** 悬浮操作栏的页签控制器（页签栏只作为沉浸光感的生效区域）。 */
  private barTabsController: HdsTabsController = new HdsTabsController();
  /** 上一次注入到文档里的顶部让位（CSS px）；值没变就不重复重排。 */
  private appliedTopPad: number = -1;
  /** 打开耗时埋点：本次文档开始加载的时刻（ms）。 */
  private docLoadAt: number = 0;
  /** 打开耗时埋点：本次文档是否已记录过首帧（同一文档只记一条）。 */
  private fcpLogged: boolean = false;
  private insetUpdateTimer: number = -1;

  private hostContext(): common.UIAbilityContext {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    return context as common.UIAbilityContext;
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

  /** 进入查找状态；打开查找条本身不弹键盘，由用户点击输入框后触发。 */
  private enterFindMode(): void {
    this.findInputActivated = false;
    if (!this.findOpen) {
      Keyboard.avoidResize();
    }
    this.findOpen = true;
    this.syncFindBottomInset();
  }

  /** 打开查找条：注入高亮支持（幂等），不自动弹键盘。 */
  private openFind(): void {
    this.findQuery = '';
    this.findCount = 0;
    this.findIndex = 0;
    this.enterFindMode();
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

  /**
   * 消费「搜索结果点进来」的待定位检索词：正文加载完成后复用页内查找定位首个命中并展开查找条。
   * 返回是否消费（true 表示本次加载以检索定位为准，不再恢复上次阅读进度）。
   */
  private consumePendingSearch(): boolean {
    const term: string = feedViewModel.pendingSearchTerm;
    if (term.length === 0) {
      return false;
    }
    feedViewModel.pendingSearchTerm = '';
    this.enterFindMode();
    this.applyFind(term);
    return true;
  }

  /**
   * 滚动即已读：生效时，进度 ≥ 80% 视为读完（标记已读并归零进度）。
   * 未开启该设置的源保持「打开即已读」的旧行为，这里不做任何事。
   */
  private handleProgressRatio(ratio: number): void {
    if (this.finished || ratio < 0.8) {
      return;
    }
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined) {
      return;
    }
    if (!feedViewModel.markReadOnScrollEffective(article.feedId)) {
      return;
    }
    this.finished = true;
    this.clearQueuedProgress();
    this.clearModePositions(article.id);
    feedViewModel.markFinished(article.id);
  }



  private clearModePositions(articleId: string): void {
    this.progressQueue.clearArticle(articleId, MODE_READER, MODE_WEB);
  }

  /** 滚动时最多每 1.2 秒写一次；切文和离开页面时立即冲刷最后的位置。 */
  private queueProgress(articleId: string, position: ReaderPosition): void {
    this.progressQueue.queue(articleId, this.viewMode, position);
  }

  private flushProgress(): void {
    this.progressQueue.flush();
  }

  private clearQueuedProgress(): void {
    this.progressQueue.clear();
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

  /** 关闭查找条：收起键盘、恢复避让模式并清掉高亮。 */
  private closeFind(): void {
    this.findOpen = false;
    this.findInputActivated = false;
    Keyboard.dismiss();
    Keyboard.popAvoidMode();
    this.clearFind();
    this.syncFindBottomInset();
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
    const articleId: string = this.cur().id;
    let segments: SpeechSegment[] = [];
    if (this.viewMode === MODE_READER && this.readerHtml.length > 0) {
      try {
        segments = parseSpeechSegments(await this.readerController.runJavaScript(collectSpeechSegmentsScript()));
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'collect speech segments failed: %{public}d', error.code);
      }
    }
    if (feedViewModel.currentArticle()?.id !== articleId) {
      return;
    }
    const text: string = segments.length > 0
      ? segments.map((item: SpeechSegment) => item.text).join(' ')
      : this.plainText();
    if (text.length === 0) {
      Toast.show($r('app.string.article_no_content'));
      return;
    }
    const language: string = speechLanguageOf(text);
    if (language.length === 0) {
      Toast.show($r('app.string.toast_speech_language_unsupported'));
      return;
    }
    // 与播客播放互斥：开始朗读前先暂停音频，避免同时出声。
    if (mediaPlayerService.status === MEDIA_PLAYING) {
      mediaPlayerService.pause().catch(() => {
      });
    }
    this.speechFollow = true;
    this.speechSegmentId = -1;
    const ok: boolean = await readerSpeech.start(text, (progress: SpeechProgress) => {
      this.speaking = progress.status !== SpeechStatus.IDLE;
      this.speechPaused = progress.status === SpeechStatus.PAUSED;
      this.speechIndex = progress.index;
      this.speechTotal = progress.total;
      this.speechSpeed = progress.speed;
      if (progress.status === SpeechStatus.IDLE) {
        this.clearSpeechMark();
        this.speechSegmentId = -1;
      } else if (progress.segmentId >= 0 && progress.segmentId !== this.speechSegmentId) {
        this.speechSegmentId = progress.segmentId;
        this.markSpeechSegment(this.speechFollow);
      }
    }, language, segments);
    if (!ok && feedViewModel.currentArticle()?.id === articleId) {
      Toast.show($r('app.string.toast_speech_unsupported'));
    }
  }

  private markSpeechSegment(follow: boolean): void {
    if (this.viewMode !== MODE_READER || this.speechSegmentId < 0) {
      return;
    }
    try {
      this.readerController.runJavaScript(markSpeechSegmentScript(this.speechSegmentId, follow))
        .catch((err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'speech mark failed: %{public}d', err.code);
        });
    } catch (_) {
      // 切文或离开页面时 Web 控制器可能已卸载。
    }
  }

  private clearSpeechMark(): void {
    try {
      this.readerController.runJavaScript(clearSpeechSegmentScript()).catch(() => {});
    } catch (_) {
    }
  }

  private returnToSpeech(): void {
    this.speechFollow = true;
    this.markSpeechSegment(true);
  }

  /** 朗读暂停 / 继续。 */
  private toggleSpeechPause(): void {
    if (this.speechPaused) {
      readerSpeech.resume();
    } else {
      readerSpeech.pause();
    }
  }

  /** 切换朗读语速（朗读中立即从当前句重读）。 */
  private cycleSpeechSpeed(): void {
    this.speechSpeed = readerSpeech.cycleSpeed();
  }

  private async copyBody(): Promise<void> {
    const text: string = this.plainText();
    if (text.length === 0) {
      Toast.show($r('app.string.article_no_content'));
      return;
    }
    const ok: boolean = await articleActions.copyText(text);
    if (ok) {
      this.snack($r('app.string.snack_body_copied'));
    } else {
      Toast.show($r('app.string.toast_action_failed'));
    }
  }

  private async shareBody(): Promise<void> {
    const text: string = this.plainText();
    if (text.length === 0) {
      Toast.show($r('app.string.article_no_content'));
      return;
    }
    const ok: boolean = await articleActions.shareText(this.hostContext(), this.cur().title, text);
    if (!ok) {
      Toast.show($r('app.string.toast_action_failed'));
    }
  }

  private async copySelection(): Promise<void> {
    const ok: boolean = await articleActions.copyText(this.selectedText);
    this.selectedText = '';
    if (ok) {
      this.snack($r('app.string.snack_selection_copied'));
    } else {
      Toast.show($r('app.string.toast_action_failed'));
    }
  }

  private async shareSelection(): Promise<void> {
    const text: string = this.selectedText;
    this.selectedText = '';
    const ok: boolean = await articleActions.shareText(this.hostContext(), this.cur().title, text);
    if (!ok) {
      Toast.show($r('app.string.toast_action_failed'));
    }
  }

  /** 用户点正文网页链接时新开应用内页；自动跳转和页内锚点留在原 Web。 */
  private openLinkedWeb(url: string): void {
    this.returnFromLinkedWeb = true;
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_LINKED_WEB, url));
  }

  private handleLinkIntercept(event: OnLoadInterceptEvent): boolean {
    const request: WebResourceRequest = event.data;
    const url: string = request.getRequestUrl();
    let currentUrl: string = this.cur().link;
    if (this.viewMode === MODE_WEB) {
      try {
        currentUrl = this.webController.getUrl();
      } catch (err) {
        // Web 尚未绑定时仍可用文章原始链接判断锚点。
      }
    }
    const target: ArticleLinkTarget = articleLinkTarget(url, currentUrl,
      request.isMainFrame(), request.isRequestGesture(), request.isRedirect());
    if (target === ArticleLinkTarget.CURRENT) {
      return false;
    }
    if (target === ArticleLinkTarget.IN_APP) {
      this.openLinkedWeb(url);
    } else {
      this.openInBrowserUrl(url);
    }
    return true;
  }

  /** 拦下 target=_blank 等新窗口，仅用户触发的网页地址进入应用内页。 */
  private handleNewWindow(event: OnWindowNewEvent): void {
    event.handler.setWebController(null);
    if (!event.isUserTrigger || event.targetUrl.length === 0) {
      return;
    }
    if (isWebLink(event.targetUrl)) {
      this.openLinkedWeb(event.targetUrl);
    } else if (!event.targetUrl.startsWith('about:') && !event.targetUrl.startsWith('data:') &&
      !event.targetUrl.startsWith('file:') && !event.targetUrl.startsWith('javascript:')) {
      this.openInBrowserUrl(event.targetUrl);
    }
  }

  private openInBrowserUrl(url: string): void {
    articleActions.openInBrowser(this.hostContext(), url).then((ok: boolean) => {
      if (!ok) {
        Toast.show($r('app.string.toast_action_failed'));
      }
    });
  }

  private async copyLink(article: Article): Promise<void> {
    const ok: boolean = await articleActions.copyText(article.link.length > 0 ? article.link : article.title);
    if (ok) {
      this.snack($r('app.string.snack_link_copied'));
    } else {
      Toast.show($r('app.string.toast_action_failed'));
    }
  }

  /**
   * 只看该源：把首页列表收敛到这篇文章的来源，并退回首页（范围 chip 显示在首页顶部，可一键清除）。
   * 源已被删时提示且不动作。
   */
  private scopeToThisFeed(article: Article): void {
    if (!feedViewModel.scopeToFeedById(article.feedId)) {
      Toast.show($r('app.string.toast_action_failed'));
      return;
    }
    this.navPathStack.popToIndex(0);
  }

  private async openInBrowser(article: Article): Promise<void> {
    const ok: boolean = await articleActions.openInBrowser(this.hostContext(), article.link);
    if (!ok) {
      Toast.show($r('app.string.toast_action_failed'));
    }
  }

  /** 当前文章的音频 / 视频附件。 */
  private audioOf(article: Article): Enclosure | undefined {
    return firstAudio(article.enclosures);
  }

  private videoOf(article: Article): Enclosure | undefined {
    return firstVideo(article.enclosures);
  }

  /** 标题下方媒体 chip 的文案（播客带时长，视频只标类型）。 */
  private mediaChipText(article: Article): ResourceStr {
    const audio: Enclosure | undefined = this.audioOf(article);
    if (audio !== undefined) {
      return audio.duration > 0
        ? $r('app.string.media_audio_with_duration', formatDuration(audio.duration))
        : $r('app.string.media_audio_label');
    }
    return $r('app.string.media_video_label');
  }

  /** 点媒体 chip：音频开始播放（本源队列），视频交给系统播放器。 */
  private mediaChipAction(): void {
    const article: Article = this.cur();
    if (this.audioOf(article) !== undefined) {
      this.playAudio(false);
    } else {
      this.openVideo();
    }
  }

  /**
   * 播放播客。
   * @param allFeeds true = 全部未听；false = 当前来源的未听队列。
   */
  private async playAudio(allFeeds: boolean): Promise<void> {
    const article: Article = this.cur();
    if (this.audioOf(article) === undefined) {
      Toast.show($r('app.string.media_error'));
      return;
    }
    const queue: Article[] = await feedViewModel.mediaQueue(article.feedId, allFeeds, true);
    let hasCurrent: boolean = false;
    for (let i = 0; i < queue.length; i += 1) {
      if (queue[i].id === article.id) {
        hasCurrent = true;
        break;
      }
    }
    if (!hasCurrent) {
      queue.unshift(article);
    }
    const ok: boolean = await mediaPlayerService.playQueue(this.hostContext(), queue, article.id);
    if (!ok) {
      Toast.show($r('app.string.media_error'));
    }
  }

  /** 打开视频：系统播放器优先，失败退浏览器。 */
  private openVideo(): void {
    const article: Article = this.cur();
    const video: Enclosure | undefined = this.videoOf(article);
    if (video === undefined) {
      return;
    }
    mediaPlayerService.openVideo(this.hostContext(), video).then((ok: boolean) => {
      if (!ok) {
        articleActions.openInBrowser(this.hostContext(), video.url).then((opened: boolean) => {
          if (!opened) {
            Toast.show($r('app.string.toast_action_failed'));
          }
        });
      }
    });
  }

  /** 打开整篇翻译：有缓存立即展示，否则发起一次翻译（用户点菜单即视为显式同意联网）。 */
  private openTranslation(): void {
    const article: Article = this.cur();
    if (article.id.length === 0) {
      return;
    }
    translationViewModel.openArticle(this.hostContext(), article.id, this.plainText()).catch(() => {
    });
    this.openSheet('translate');
  }

  /** 翻译当前选中的文本：与整篇翻译共用面板，选段结果置顶。 */
  private translateSelected(): void {
    const text: string = this.selectedText.trim();
    if (text.length === 0) {
      return;
    }
    translationViewModel.translateSelection(this.hostContext(), text).catch(() => {
    });
    this.openSheet('translate');
  }

  /**
   * 打开统一分享面板（三处入口复用同一个 ShareSheet）。
   * 顺序：先把当前文章转成 ShareContext 写入 ShareViewModel，再翻起半模态 —— 面板首帧就能拿到正确上下文。
   */
  private async openSharePanel(): Promise<void> {
    const article: Article = this.cur();
    if (article.id.length === 0) {
      Toast.show($r('app.string.toast_action_failed'));
      return;
    }
    const ctx: ShareContext = await shareService.articleContext(article);
    await shareViewModel.open(this.hostContext(), ctx);
    this.openSheet('share');
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
      if (feedViewModel.currentArticle()?.id !== article.id) {
        return;
      }
      if (html.length > 0) {
        this.readerHtml = html;
        this.viewMode = MODE_READER;
        // 提取成功说明这个站点不再需要「只用网页原文」：清掉站点记忆，下次照常走阅读器。
        if (article.link.length > 0) {
          settingsStore.preferReaderSite(UrlText.host(article.link));
        }
        const hasRemoteImage: boolean = /<img\b[^>]*\bsrc="https?:/i.test(html);
        if (hasRemoteImage && (html.startsWith('<!--hrv9p-->') || !NetworkStatus.isOnline())) {
          Toast.show($r('app.string.article_offline_images_pending'));
        }
        if (webMounted) {
          // Web 已挂载（原地切文）：直接换文档，避免销毁重建导致 controller 失效。
          this.loadReaderDocIntoWeb();
        }
        // 否则由 onControllerAttached 在新 Web 挂载时加载。
      } else {
        this.onReaderFailed();
      }
    } catch (err) {
      if (feedViewModel.currentArticle()?.id !== article.id) {
        return;
      }
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'reader extract failed: %{public}d', error.code);
      this.onReaderFailed(err instanceof ReaderPlaceholderError || err instanceof ReaderNeedsJsError);
    }
  }

  /** 把当前 readerHtml 载入已挂载的 Reader Web。 */
  private loadReaderDocIntoWeb(): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || this.readerHtml.length === 0) {
      return;
    }
    const start: number = Date.now();
    const topPad: number = this.readerTopPad();
    this.appliedTopPad = topPad;
    const doc: string = buildReaderDocument(this.readerHtml, topPad, this.contentBottomInsetVp());
    this.beginDocLoad();
    try {
      this.readerController.loadData(doc, 'text/html', 'UTF-8', article.link);
      hilog.info(DOMAIN, TAG, 'perf docbuild=%{public}dms size=%{public}d',
        Date.now() - start, doc.length);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'load reader doc failed: %{public}d', error.code);
    }
  }

  /** 打开耗时埋点：重置本次文档的计时起点，等 Web 回传首帧。 */
  private beginDocLoad(): void {
    this.docLoadAt = Date.now();
    this.fcpLogged = false;
    // 新文档里还没有任何标注标记：允许页面加载完成时跳过空标注注入。
    this.highlightInjected = false;
  }

  /**
   * 打开耗时埋点：Web 侧 navigationStart → 首次内容绘制（ms）。
   * 同一文档只记一条；Web 的 FCP 是相对导航起点的绝对耗时，不依赖本地计时器。
   */
  private logFirstPaint(ms: number, mode: string): void {
    if (this.fcpLogged) {
      return;
    }
    this.fcpLogged = true;
    const chars: number = mode === MODE_WEB ? 0 : this.readerHtml.length;
    const sinceDoc: number = this.docLoadAt > 0 ? Date.now() - this.docLoadAt : -1;
    hilog.info(DOMAIN, TAG, 'perf fcp=%{public}dms sinceDoc=%{public}dms chars=%{public}d mode=%{public}s',
      ms, sinceDoc, chars, mode);
  }

  /** 首帧事件没有触发时（个别文档）用 pageEnd 兜底，保证基线里每篇都有数据。 */
  private logPageEndFallback(mode: string): void {
    if (this.fcpLogged) {
      return;
    }
    this.fcpLogged = true;
    const sinceDoc: number = this.docLoadAt > 0 ? Date.now() - this.docLoadAt : -1;
    const chars: number = mode === MODE_WEB ? 0 : this.readerHtml.length;
    hilog.info(DOMAIN, TAG, 'perf pageend=%{public}dms chars=%{public}d mode=%{public}s',
      sinceDoc, chars, mode);
  }

  /**
   * 正文顶部让位（CSS px）：状态栏 + 标题栏 + 有 chips 时一条标签条的高度。
   *
   * 正文铺到屏幕最顶端（连状态栏区域都是正文），首行被这段内边距推到标题栏下沿之外；
   * 滚动时正文依次从状态栏、标题栏下方穿过，被顶部的模糊背板压住。
   */
  private readerTopPad(): number {
    return safeArea.topInsetVp + CommonConstants.TITLE_BAR_HEIGHT_VP
      + (this.hasTopChips() ? TAG_STRIP_VP : 0);
  }

  /** 正文末尾留白跟随当前底栏高度，查找时可滚到双行面板上方。 */
  private contentBottomInsetVp(): number {
    return safeArea.contentBottomInsetVp +
      (this.findOpen ? FIND_BAR_HEIGHT_VP - CommonConstants.TAB_BAR_HEIGHT_VP : 0);
  }

  /** 切换查找模式时原地更新已加载正文的底部留白。 */
  private syncFindBottomInset(): void {
    const topPad: number = this.readerTopPad();
    const bottomPad: number = this.contentBottomInsetVp();
    if (this.viewMode === MODE_WEB) {
      readerStyle.apply(this.webController, topPad, bottomPad);
    } else if (this.readerHtml.length > 0) {
      try {
        this.readerController.runJavaScript(readerStyleScript(topPad, bottomPad)).catch((err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'find inset inject failed: %{public}d', err.code);
        });
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'find inset before attach failed: %{public}d', error.code);
      }
    }
  }

  /** chips 异步就绪 / 变化后重新注入顶部让位（幂等：值没变直接返回）。 */
  private scheduleReaderInset(): void {
    if (this.insetUpdateTimer >= 0) {
      clearTimeout(this.insetUpdateTimer);
    }
    this.insetUpdateTimer = setTimeout(() => {
      this.insetUpdateTimer = -1;
      this.syncReaderInset();
    }, 16);
  }

  private syncReaderInset(): void {
    const next: number = this.readerTopPad();
    if (next === this.appliedTopPad) {
      return;
    }
    if (this.viewMode === MODE_WEB) {
      this.appliedTopPad = next;
      readerStyle.apply(this.webController, next, this.contentBottomInsetVp());
      return;
    }
    if (this.readerHtml.length === 0) {
      return;
    }
    this.appliedTopPad = next;
    try {
      this.readerController
        .runJavaScript(readerStyleScript(next, this.contentBottomInsetVp()))
        .catch((err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'inset inject failed: %{public}d', err.code);
        });
    } catch (err) {
      // onAreaChange 可能先于 Web 控制器挂载；onPageEnd 会按当前尺寸再补一次。
      const error: BusinessError = err as BusinessError;
      this.appliedTopPad = -1;
      hilog.warn(DOMAIN, TAG, 'inset before attach failed: %{public}d', error.code);
    }
  }

  /**
   * 预取下一篇正文：读完当前文章停顿一会儿后，在非计费网络下提前提取好下一篇，
   * 横向滑过去时正文已经命中缓存，不再等 spinnner。
   */
  private schedulePrefetch(): void {
    if (this.prefetchTimer >= 0) {
      clearTimeout(this.prefetchTimer);
      this.prefetchTimer = -1;
    }
    if (!appSettings.prefetchReader || !NetworkStatus.isUnmetered()) {
      return;
    }
    this.prefetchTimer = setTimeout(() => {
      this.prefetchTimer = -1;
      const nextId: string = feedViewModel.nextArticleId();
      if (nextId.length === 0) {
        return;
      }
      feedViewModel.prefetchReader(nextId).catch(() => {
      });
    }, 1500);
  }

  /** 提取失败：有链接就退网页原文，否则退纯文本（loading 由对应视图的 onPageEnd 收尾）。 */
  private onReaderFailed(needsWebRender: boolean = false): void {
    this.readerFailed = true;
    const article: Article | undefined = feedViewModel.currentArticle();
    if (!NetworkStatus.isOnline()) {
      this.viewMode = MODE_READER;
      this.readerHtml = '';
      this.loading = false;
      Toast.show($r('app.string.article_offline_body_fallback'));
      return;
    }
    if (article !== undefined && article.link.length > 0) {
      // 只在「确定性失败」（SPA 空壳 / 占位内容）时记住站点；
      // 超时 / 断网 / 解析异常是一次性的，不能把站点永久锁进加载更慢的网页原文。
      if (needsWebRender) {
        settingsStore.rememberReaderSiteWeb(UrlText.host(article.link));
      }
      this.preconnectWeb(article.link);
      this.viewMode = MODE_WEB;
      this.webFailed = false;
      this.loading = true;
      Toast.show(needsWebRender ? $r('app.string.article_reader_placeholder') : $r('app.string.article_reader_failed'));
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
    // 同时记住「这个站点」的选择：网页原文 → 下次该站直接进 Web；
    // 正文 → 忘掉之前「需要 JS」的记录。
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || article.link.length === 0) {
      return;
    }
    const host: string = UrlText.host(article.link);
    if (mode === MODE_WEB) {
      settingsStore.rememberReaderSiteWeb(host);
      this.preconnectWeb(article.link);
    } else {
      settingsStore.preferReaderSite(host);
    }
  }

  /**
   * 网页原文预连接：提前解析 + 建立 TCP 连接，首屏少等一轮 DNS / 握手。
   * 只在 Web 模式或即将退回 Web 时调用；失败不影响正常加载。
   */
  private preconnectWeb(link: string): void {
    if (link.length === 0) {
      return;
    }
    try {
      webview.WebviewController.prepareForPageLoad(link, true, 6);
    } catch (err) {
      // 预连接是尽力而为：URL 非法 / 引擎未就绪都直接忽略。
    }
  }

  // ---- 标签（标题下方 chips） ----

  /** 读出当前文章的标签（切换文章 / 打标完成后都调一次）。 */
  private async loadTags(): Promise<void> {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined) {
      this.articleTags = [];
      return;
    }
    this.articleTags = await tagViewModel.tagsOf(article.id);
    this.syncReaderInset();
  }

  /** 打开标签选择器（复用底部面板，见 sheetMode = 'tags'）。 */
  private openTagSheet(): void {
    this.openSheet('tags');
  }

  // ---- 来源（跨源去重：标题下方来源 chip + 来源面板） ----

  /**
   * 读出当前文章所属合并组的全部来源（切换文章后都要调一次）。
   * 单来源文章只返回自己一条，界面据此保持现状、不显示任何来源标识。
   */
  private async loadSources(): Promise<void> {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined) {
      this.groupSources = [];
      return;
    }
    try {
      this.groupSources = await articleRepository.loadGroupSources(article.id);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'load group sources failed: %{public}d', error.code);
      this.groupSources = [];
    }
    this.syncReaderInset();
  }

  /** 是否是多来源合并出的文章（只在 >1 时展示来源入口）。 */
  private merged(): boolean {
    return this.groupSources.length > 1;
  }

  /** 打开来源面板（复用底部面板，见 sheetMode = 'sources'）。 */
  private openSourceSheet(): void {
    this.openSheet('sources');
  }

  /** 打开某个来源的原文链接（失败给即时提示）。 */
  private openSource(source: GroupSource): void {
    if (source.link.length === 0) {
      Toast.show($r('app.string.dedupe_open_failed'));
      return;
    }
    articleActions.openInBrowser(this.hostContext(), source.link).then((ok: boolean) => {
      if (!ok) {
        Toast.show($r('app.string.dedupe_open_failed'));
      }
    });
  }

  private hasTagId(id: string): boolean {
    for (let i = 0; i < this.articleTags.length; i += 1) {
      if (this.articleTags[i].id === id) {
        return true;
      }
    }
    return false;
  }

  /**
   * 选择器确认：把差异写回库（只增删本篇文章的关联），随后刷新 chips 与标签计数。
   * 以「差集」而不是全量重建：不误删文章上其它标签，也不会重复插入已有标签。
   */
  private async applyTagSelection(ids: string[]): Promise<void> {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined) {
      return;
    }
    const removed: TagWithCount[] = this.articleTags.filter((tag: TagWithCount) => ids.indexOf(tag.id) < 0);
    const added: string[] = ids.filter((id: string) => !this.hasTagId(id));
    for (let i = 0; i < removed.length; i += 1) {
      await tagViewModel.removeTagFromArticle(removed[i].id, article.id);
    }
    for (let i = 0; i < added.length; i += 1) {
      await tagViewModel.addTagsToArticles([article.id], added[i]);
    }
    if (removed.length > 0 || added.length > 0) {
      await tagViewModel.load();
    }
    await this.loadTags();
  }

  /** 当前文章的标签 id（给选择器做初始选中）。 */
  private tagIds(): string[] {
    return this.articleTags.map((tag: TagWithCount) => tag.id);
  }

  // ---- 正文标注（高亮 + 备注） ----

  /** 读出当前文章的标注并重放到正文里。 */
  private async loadHighlights(): Promise<void> {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined) {
      this.highlights = [];
      return;
    }
    this.highlights = await highlightStore.listHighlights(article.id);
    this.replayHighlights(this.activeController());
    // 从标注聚合页点进来：定位到那条标注（消费后清空，避免切文又跳一次）。
    const pending: string = feedViewModel.pendingHighlightId;
    if (pending.length > 0) {
      feedViewModel.pendingHighlightId = '';
      const target: Highlight | undefined = this.findHighlight(pending);
      if (target !== undefined) {
        this.gotoHighlight(target);
      }
    }
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
    // 文档里本来就没有标记、也没有标注：跳过两次 JS 往返（打开文章时省掉一次跨语言调用）。
    // 一旦注入过（含删除后需要清除的情况），即使 items 为空也要执行 apply 去清标记。
    if (items.length === 0 && !this.highlightInjected) {
      return;
    }
    this.highlightInjected = items.length > 0;
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
      highlightStore.addHighlight(item);
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
    highlightStore.updateHighlightNote(item.id, item.note);
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
    highlightStore.updateHighlightColor(id, color);
    this.replayHighlights(this.activeController());
  }

  /** 删除标注。 */
  private removeHighlight(id: string): void {
    highlightStore.deleteHighlight(id);
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
    if (this.viewMode === MODE_READER && article.link.length === 0) {
      return;
    }
    this.stopProgressPolling();
    this.flushProgress();
    if (this.viewMode === MODE_WEB) {
      this.persistWebProgress();
    } else {
      this.persistReaderProgress();
    }
    readerSpeech.stop();
    this.speechFollow = true;
    this.speechSegmentId = -1;
    if (this.viewMode === MODE_READER) {
      this.applyViewMode(MODE_WEB);
      this.webFailed = false;
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
  /**
   * 详情页键盘快捷键（仅在无半模态 / 查找条时生效）：
   * j / k = 下 / 上篇，m = 切换已读，s = 切换收藏，/ = 搜索，Esc = 关闭查找或返回。
   * 返回 true 表示事件已消费，阻止继续冒泡。
   */
  private handleShortcut(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    const code: number = event.keyCode;
    if (code === KeyCode.KEYCODE_ESCAPE || code === 1) {
      if (this.findOpen) {
        this.closeFind();
      } else if (!this.showSheet) {
        this.navPathStack.pop();
      }
      return true;
    }
    if (this.findOpen || this.showSheet) {
      // 查找条 / 半模态里正在输入或选择，不劫持按键。
      return false;
    }
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined) {
      return false;
    }
    if (code === KeyCode.KEYCODE_J || code === 36) {
      const next: string = feedViewModel.nextArticleId();
      if (next.length === 0) {
        return false;
      }
      this.openRelative(next, 1);
      return true;
    }
    if (code === KeyCode.KEYCODE_K || code === 37) {
      const prev: string = feedViewModel.prevArticleId();
      if (prev.length === 0) {
        return false;
      }
      this.openRelative(prev, -1);
      return true;
    }
    if (code === KeyCode.KEYCODE_M || code === 50) {
      feedViewModel.toggleRead(article.id);
      return true;
    }
    if (code === KeyCode.KEYCODE_S || code === 31) {
      feedViewModel.toggleStar(article.id);
      return true;
    }
    if (code === KeyCode.KEYCODE_SLASH || code === 53) {
      this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_SEARCH, ''));
      return true;
    }
    return false;
  }

  private openRelative(id: string, slideFrom: number = 1): void {
    if (id.length === 0) {
      return;
    }
    this.stopProgressPolling();
    this.flushProgress();
    if (this.viewMode === MODE_WEB) {
      this.persistWebProgress();
    } else {
      this.persistReaderProgress();
    }
    if (this.prefetchTimer >= 0) {
      clearTimeout(this.prefetchTimer);
      this.prefetchTimer = -1;
    }
    // 先结束旧文的查找，避免清理脚本误作用于新文档。
    if (this.findOpen) {
      this.closeFind();
    }
    feedViewModel.openArticle(id);
    // 不重置 readerHtml：保持 Reader Web 挂载，随后直接换文档，避免 controller 失效。
    this.progressRatio = feedViewModel.currentArticle()?.progressRatio ?? 0;
    this.progressReadyAt = 0;
    // 换了文章：停掉朗读
    readerSpeech.stop();
    this.speechFollow = true;
    this.speechSegmentId = -1;
    // 新文章从完整界面开始。
    this.findQuery = '';
    this.findCount = 0;
    this.findIndex = 0;
    this.readerFailed = false;
    this.webFailed = false;
    this.shortBodyHintClosed = false;
    this.webProgressRestored = false;
    this.readerProgressRestored = false;
    // 新文章的 chips 可能不同：顶部让位需要按新文章重新注入。
    this.appliedTopPad = -1;
    this.finished = false;
    this.loading = true;
    if (this.viewMode === MODE_READER) {
      this.startReader();
    }
    // 网页原文模式：Web 的 src 随 article.link 变化自动重载，等 onPageEnd 收尾。
    this.playSwitchAnimation(slideFrom);
    this.loadHighlights();
    this.loadTags();
    this.loadSources();
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
    // 新文章的 chips 可能不同：顶部让位需要按新文章重新注入。
    this.appliedTopPad = -1;
    this.finished = false;
    this.viewMode = MODE_READER;
    this.startReader();
  }

  /**
   * 网页原文 → 正文：把已渲染的 DOM 交回提取器。
   * Tabs / 远程数据渲染完的页面，静态 HTML 里没有正文，只有这一步能拿到。
   */
  private async extractRenderedPage(): Promise<void> {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || article.link.length === 0) {
      return;
    }
    const articleId: string = article.id;
    let raw: string = '';
    try {
      raw = await this.webController.runJavaScript('JSON.stringify(document.documentElement.outerHTML)');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'read rendered dom failed: %{public}d', error.code);
      Toast.show($r('app.string.article_reader_failed'));
      return;
    }
    const html: string = decodeJsResultString(raw);
    if (html.length === 0) {
      Toast.show($r('app.string.article_reader_failed'));
      return;
    }
    const fragment: string = feedViewModel.adoptRenderedHtml(articleId, html);
    if (fragment.length === 0) {
      Toast.show($r('app.string.article_reader_failed'));
      return;
    }
    if (feedViewModel.currentArticle()?.id !== articleId) {
      return;
    }
    this.stopProgressPolling();
    this.persistWebProgress();
    this.readerHtml = fragment;
    this.readerFailed = false;
    this.webFailed = false;
    this.readerProgressRestored = false;
    this.shortBodyHintClosed = false;
    // 用户主动选择正文 → 记住该站点，并把全局偏好也切回阅读器。
    this.applyViewMode(MODE_READER);
    Toast.show($r('app.string.article_reader_ready'));
  }

  /**
   * SPA 站点进入网页原文后，等页面渲染稳定再抓一次 DOM 存成正文（离线可读）。
   * 只对「之前提取失败过」的 host 执行，普通站点不额外跑脚本。
   */
  private scheduleWebSnapshot(): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || article.link.length === 0 || this.webSnapshotPending) {
      return;
    }
    if (article.readerHtml.length > 0 || this.webSnapshotArticleId === article.id) {
      return;
    }
    if (!NetworkStatus.isOnline() || !settingsStore.isReaderSiteWebPreferred(UrlText.host(article.link))) {
      return;
    }
    const articleId: string = article.id;
    this.webSnapshotPending = true;
    setTimeout(() => {
      this.webSnapshotPending = false;
      this.captureWebSnapshot(articleId).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'web snapshot failed: %{public}d', err.code);
      });
    }, WEB_SNAPSHOT_DELAY_MS);
  }

  /** 抓网页原文的 DOM 存成正文缓存（不切模式，静默失败）。 */
  private async captureWebSnapshot(articleId: string): Promise<void> {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || article.id !== articleId || this.viewMode !== MODE_WEB) {
      return;
    }
    if (this.webSnapshotArticleId === articleId) {
      return;
    }
    this.webSnapshotArticleId = articleId;
    let raw: string = '';
    try {
      raw = await this.webController.runJavaScript('JSON.stringify(document.documentElement.outerHTML)');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'snapshot read dom failed: %{public}d', error.code);
      return;
    }
    const html: string = decodeJsResultString(raw);
    if (html.length === 0) {
      return;
    }
    const fragment: string = feedViewModel.adoptRenderedHtml(articleId, html);
    if (fragment.length > 0) {
      hilog.info(DOMAIN, TAG, 'web snapshot cached (%{public}d chars)', fragment.length);
    }
  }

  private async downloadCurrentOffline(retry: boolean): Promise<void> {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || this.offlineBusy) {
      return;
    }
    this.offlineBusy = true;
    let state: string = 'none';
    try {
      state = await feedViewModel.downloadArticleOffline(article.id, retry);
    } catch (err) {
      state = 'none';
    } finally {
      this.offlineBusy = false;
    }
    if (state === 'full') {
      Toast.show($r('app.string.offline_full'));
    } else if (state === 'text' || state === 'partial') {
      Toast.show($r('app.string.offline_partial'));
    } else {
      Toast.show($r('app.string.offline_single_failed'));
    }
  }

  private async clearCurrentOffline(): Promise<void> {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || this.offlineBusy) {
      return;
    }
    this.offlineBusy = true;
    let cleared: boolean = false;
    try {
      cleared = await feedViewModel.clearArticleOffline(article.id);
    } catch (err) {
      cleared = false;
    } finally {
      this.offlineBusy = false;
    }
    Toast.show(cleared ? $r('app.string.offline_single_cleared') : $r('app.string.offline_single_failed'));
  }

  /** 重载失败的网页原文，不重置文章的阅读位置。 */
  private retryWeb(): void {
    this.webFailed = false;
    this.loading = true;
    this.webProgressRestored = false;
    try {
      this.webController.refresh();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'reload web failed: %{public}d', error.code);
      this.webFailed = true;
      this.loading = false;
    }
  }

  /** 只将顶层页面的加载错误显示为错误页。 */
  private failWeb(): void {
    this.stopProgressPolling();
    this.webFailed = true;
    this.loading = false;
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
    const articleId: string = feedViewModel.currentArticle()?.id ?? '';
    if (articleId.length === 0) {
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
        if (feedViewModel.currentArticle()?.id === articleId) {
          this.finished = true;
          this.clearModePositions(articleId);
          feedViewModel.markFinished(articleId);
        }
      });
  }

  /** 溢出菜单：重新提取 / 复制链接 / 浏览器打开 / 分享（统一交给 AppMenu 渲染，规格现算）。 */
  @Builder
  ActionsMenu(article: Article) {
    AppMenu(this.actionsMenuSpec(article));
  }

  /**
   * 溢出菜单的规格：条目、条件分支与顺序与改造前逐条一致，不许增删或重排。
   * 图标走 withIcon（HM Symbol），下载中置灰走 withEnabled，
   * 「清除离线缓存」是删除动作标危险色。
   */
  private actionsMenuSpec(article: Article): MenuSpec {
    const items: MenuItemSpec[] = [];
    // 离线状态文案：已存全量 / 仅文本 / 未存；只有「未存」且空闲时可点。
    const offlineLabel: ResourceStr = article.offlineState === 'full' ? $r('app.string.offline_full') :
      (article.offlineState === 'text' || article.offlineState === 'partial' ?
        $r('app.string.offline_partial') : $r('app.string.offline_single_download'));
    items.push(new MenuItemSpec('offline_download', offlineLabel, (): void => {
      this.downloadCurrentOffline(false);
    }).withIcon($r('sys.symbol.arrow_down'))
      .withEnabled(!this.offlineBusy && article.offlineState === 'none'));
    if (article.offlineState === 'text' || article.offlineState === 'partial') {
      items.push(new MenuItemSpec('offline_retry', $r('app.string.offline_single_retry'), (): void => {
        this.downloadCurrentOffline(true);
      }).withIcon($r('sys.symbol.arrow_clockwise'))
        .withEnabled(!this.offlineBusy));
    }
    if (article.offlineState !== 'none') {
      items.push(new MenuItemSpec('offline_clear', $r('app.string.offline_single_clear'), (): void => {
        this.clearCurrentOffline();
      }).withIcon($r('sys.symbol.trash'))
        .withEnabled(!this.offlineBusy)
        .markDanger());
    }
    items.push(new MenuItemSpec('reader_retry', $r('app.string.action_reader_retry'), (): void => {
      this.retryReader();
    }).withIcon($r('sys.symbol.arrow_clockwise')));
    // 网页原文模式：把已渲染的 DOM 再提取一次（SPA 站点只有 JS 跑完才有正文）。
    if (this.viewMode === MODE_WEB && article.link.length > 0) {
      items.push(new MenuItemSpec('render_extract', $r('app.string.action_extract_rendered'), (): void => {
        this.extractRenderedPage();
      }).withIcon($r('sys.symbol.magnifyingglass')));
    }
    items.push(new MenuItemSpec('speech',
      this.speaking ? $r('app.string.action_stop_speech') : $r('app.string.action_start_speech'), (): void => {
        this.toggleSpeech();
      }).withIcon(this.speaking ? $r('sys.symbol.stop_circle') : $r('sys.symbol.speaker')));
    if (this.audioOf(article) !== undefined) {
      items.push(new MenuItemSpec('audio_feed', $r('app.string.media_play_audio_feed'), (): void => {
        this.playAudio(false);
      }).withIcon($r('sys.symbol.headphones')));
      items.push(new MenuItemSpec('audio_all', $r('app.string.media_play_audio_all'), (): void => {
        this.playAudio(true);
      }).withIcon($r('sys.symbol.headphones')));
    }
    if (this.videoOf(article) !== undefined) {
      items.push(new MenuItemSpec('video', $r('app.string.media_open_video'), (): void => {
        this.openVideo();
      }).withIcon($r('sys.symbol.play_video')));
    }
    items.push(new MenuItemSpec('toc', $r('app.string.action_toc'), (): void => {
      this.openToc();
    }).withIcon($r('sys.symbol.text_alignleft')));
    items.push(new MenuItemSpec('find', $r('app.string.action_find_in_article'), (): void => {
      this.openFind();
    }).withIcon($r('sys.symbol.magnifyingglass')));
    items.push(new MenuItemSpec('translate', $r('app.string.translate_action_full'), (): void => {
      this.openTranslation();
    }).withIcon($r('sys.symbol.translate')));
    items.push(new MenuItemSpec('copy_body', $r('app.string.action_copy_body'), (): void => {
      this.copyBody();
    }).withIcon($r('sys.symbol.text_clipboard')));
    items.push(new MenuItemSpec('share_body', $r('app.string.action_share_body'), (): void => {
      this.shareBody();
    }).withIcon($r('sys.symbol.share')));
    items.push(new MenuItemSpec('copy_link', $r('app.string.action_copy_link'), (): void => {
      this.copyLink(article);
    }).withIcon($r('sys.symbol.link')));
    items.push(new MenuItemSpec('highlight_list', $r('app.string.hl_panel_entry'), (): void => {
      this.openSheet('hlList');
    }).withIcon($r('sys.symbol.paintpalette')));
    items.push(new MenuItemSpec('scope_feed', $r('app.string.action_scope_feed'), (): void => {
      this.scopeToThisFeed(article);
    }).withIcon($r('sys.symbol.folder')));
    items.push(new MenuItemSpec('open_browser', $r('app.string.action_open_browser'), (): void => {
      this.openInBrowser(article);
    }).withIcon($r('sys.symbol.arrow_right_up_and_square')));
    items.push(new MenuItemSpec('share', $r('app.string.action_share'), (): void => {
      this.openSharePanel();
    }).withIcon($r('sys.symbol.share')));
    return MenuSpec.fromItems(items);
  }

  /**
   * 站点被记为「需要网页原文」时：先确认这篇有没有 Reader 缓存。
   * 有缓存就仍走正文（缓存命中不发请求），没有才进网页原文。
   */
  private async openSiteMemoArticle(article: Article): Promise<void> {
    this.viewMode = MODE_READER;
    this.loading = true;
    await feedViewModel.ensureBodyLoaded(article.id);
    if (feedViewModel.currentArticle()?.id !== article.id) {
      return;
    }
    if (article.readerHtml.length > 0) {
      this.startReader();
      return;
    }
    this.preconnectWeb(article.link);
    this.viewMode = MODE_WEB;
    this.loading = true;
  }

  aboutToAppear(): void {
    readingContinuation.setDetailVisible(true);
    if (this.returnFromLinkedWeb) {
      this.returnFromLinkedWeb = false;
      this.startProgressPolling(this.viewMode === MODE_WEB ? this.webController : this.readerController);
      if (appSettings.readerKeepScreenOn) {
        screenAwake.set(true, this.getUIContext().getHostContext());
      }
      return;
    }
    // 恢复上次用的阅读模式：上次停在「网页原文」时直接进 Web，
    // 不能再跑一遍 startReader()（它会无条件把 viewMode 拽回阅读器）。
    const article: Article | undefined = feedViewModel.currentArticle();
    this.progressRatio = article?.progressRatio ?? 0;
    // 站点记忆：该 host 之前正文提取失败过（SPA 空壳），直接进网页原文，
    // 不再每篇都白跑一次「抓 HTML → 提取失败 → 回退」。
    // 但这篇若已有 Reader 缓存，仍然优先正文：网页原文只会更慢，还浪费已缓存的内容。
    const siteNeedsWeb: boolean = article !== undefined && article.link.length > 0 &&
      settingsStore.isReaderSiteWebPreferred(UrlText.host(article.link));
    if (appSettings.readerViewMode === MODE_WEB && article !== undefined && article.link.length > 0) {
      this.preconnectWeb(article.link);
      this.viewMode = MODE_WEB;
      this.loading = true;
    } else if (siteNeedsWeb && article !== undefined) {
      this.openSiteMemoArticle(article).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'open site memo article failed: %{public}d', err.code);
        this.viewMode = MODE_WEB;
        this.loading = true;
      });
    } else {
      this.viewMode = MODE_READER;
      this.startReader();
    }
    this.loadHighlights();
    this.loadTags();
    this.loadSources();
    if (appSettings.readerKeepScreenOn) {
      screenAwake.set(true, this.getUIContext().getHostContext());
    }
  }

  /** 离开详情页：恢复系统息屏策略，并按当前模式取一次滚动位置写回。 */
  aboutToDisappear(): void {
    readingContinuation.setDetailVisible(false);
    if (this.insetUpdateTimer >= 0) {
      clearTimeout(this.insetUpdateTimer);
      this.insetUpdateTimer = -1;
    }
    if (this.findOpen) {
      this.closeFind();
    }
    if (this.prefetchTimer >= 0) {
      clearTimeout(this.prefetchTimer);
      this.prefetchTimer = -1;
    }
    screenAwake.set(false, this.getUIContext().getHostContext());
    readerSpeech.release();
    this.stopProgressPolling();
    this.flushProgress();
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
   * 持续 5 秒以覆盖图片晚加载；用户主动操作会立即停止校正。
   */
  private restoreScrollProgress(controller: webview.WebviewController, restored: boolean): void {
    if (restored) {
      return;
    }
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined) {
      return;
    }
    const position: ReaderPosition = this.progressQueue.positionOf(article.id, this.viewMode) ??
      new ReaderPosition(article.progress, article.progressRatio);
    if (position.y <= 0 && position.ratio <= 0) {
      return;
    }
    this.progressReadyAt = Date.now() + 5200;
    this.runRestore(controller, position);
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

  /**
   * 点按 / 长按正文：问文档「这个坐标上是图片吗」，是图片就打开大图。
   * 底栏常驻显示，点按正文不再切换任何栏的显隐。
   */
  private handleBodyTap(localX: number, localY: number): void {
    this.activeController().runJavaScript(imageAtPointScript(localX, localY))
      .then((raw: string) => {
        const src: string = this.decodeJsString(raw);
        if (src.length > 0) {
          this.viewerSrc = src;
          this.viewerOpen = true;
        }
      })
      .catch(() => {
        // 命中测试失败（页面未就绪等）：不打断阅读。
      });
  }

  /** runJavaScript 的字符串结果可能被 JSON 序列化包一层引号 / 转义。 */
  private decodeJsString(raw: string): string {
    let text: string = raw.trim();
    if (text.length > 1 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1);
    }
    return text.replace(/\\"/g, '"').replace(/\\\//g, '/').replace(/\\\\/g, '\\');
  }

  /** 保存图片到相册（授权由查看器里的保存控件完成）。 */
  private saveImage(src: string): void {
    readerImageSave.save(this.hostContext(), src, this.cur().link).then((ok: boolean) => {
      if (ok) {
        this.snack($r('app.string.image_saved'));
      } else {
        Toast.show($r('app.string.image_save_failed'));
      }
    }).catch(() => {
      Toast.show($r('app.string.image_save_failed'));
    });
  }

  /**
   * 进度兜底轮询：正常情况下滚动由文档内 hrProgress.onScroll 实时上报（见 onProgressReported），
   * 这里只做低频兜底 —— 某些页面（自定义滚动容器、脚本被拦截）拿不到滚动事件时仍能取到位置。
   */
  private startProgressPolling(controller: webview.WebviewController): void {
    this.stopProgressPolling();
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined) {
      return;
    }
    const articleId: string = article.id;
    const mode: string = this.viewMode;
    const version: number = this.progressPollVersion;
    this.lastPolledY = -1;
    this.progressBridgeSeen = false;
    const poll = (): void => {
      if (version !== this.progressPollVersion || feedViewModel.currentArticle()?.id !== articleId ||
        this.viewMode !== mode || Date.now() < this.progressReadyAt) {
        return;
      }
      controller.runJavaScript(readPositionScript()).then((raw: string) => {
        if (version !== this.progressPollVersion || feedViewModel.currentArticle()?.id !== articleId ||
          this.viewMode !== mode || Date.now() < this.progressReadyAt) {
          return;
        }
        if (raw.indexOf('|') < 0) {
          return;
        }
        this.applyProgressPosition(articleId, parsePosition(raw));
      }).catch(() => {});
    };
    this.progressPollTimer = setInterval(poll, 4000);
    poll();
  }

  /** 文档内滚动上报：算位置 → 更新进度条 / 已读判定 / 位置落库（滚动停 1.2 秒写一次）。 */
  private onProgressReported(y: number, h: number, vh: number): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || Date.now() < this.progressReadyAt) {
      return;
    }
    if (!this.progressBridgeSeen) {
      this.progressBridgeSeen = true;
      hilog.info(DOMAIN, TAG, 'perf progress bridge attached mode=%{public}s', this.viewMode);
    }
    const position: ReaderPosition = positionFromMetrics(y, h, vh);
    this.applyProgressPosition(article.id, position);
  }

  /** 轮询与滚动上报共用的落点逻辑（避免两套口径）。 */
  private applyProgressPosition(articleId: string, position: ReaderPosition): void {
    if (feedViewModel.currentArticle()?.id !== articleId) {
      return;
    }
    // 位置没变就不重复更新时间戳 / 写库（轮询每 4 秒一次也算兜底，不能造成无谓写入）。
    if (Math.abs(position.y - this.lastPolledY) < 1) {
      return;
    }
    this.lastPolledY = position.y;
    // 进度条是 @Local：滚动上报 5 次/秒，若每次都重建整页会反向拖慢滑动。
    // 这里按 ~4 次/秒节流，且变化不足 1% 不刷新；写库用的位置不受影响。
    const next: number = Math.round(position.ratio * 100) / 100;
    const now: number = Date.now();
    if (next !== this.progressRatio && (now - this.progressRatioAt >= 250 || Math.abs(next - this.progressRatio) >= 0.05)) {
      this.progressRatioAt = now;
      this.progressRatio = next;
    }
    this.handleProgressRatio(position.ratio);
    if (!this.finished) {
      this.queueProgress(articleId, position);
    }
  }

  private stopProgressPolling(): void {
    this.progressPollVersion++;
    if (this.progressPollTimer >= 0) {
      clearInterval(this.progressPollTimer);
      this.progressPollTimer = -1;
    }
  }

  /**
   * 正文触摸判定：短按、几乎没位移 → 视为点按（用于图片命中）。
   * 放在 ArkTS 侧而不是注入脚本：ArkWeb 里 text 区域的合成点按不一定抛出 DOM click 事件（实测点按回调收不到）。
   */
  private handleBodyTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      // 用户主动触摸会取消文档内的恢复脚本，下一次轮询可立即记住新位置。
      this.progressReadyAt = 0;
      if (event.touches.length > 0) {
        // 组件内坐标（vp）用于图片命中。
        this.tapLocalX = event.touches[0].x;
        this.tapLocalY = event.touches[0].y;
        this.tapStartX = event.touches[0].windowX;
        this.tapStartY = event.touches[0].windowY;
        this.tapStartTime = Date.now();
      }
      return;
    }
    if (event.type !== TouchType.Up || this.tapStartTime === 0) {
      return;
    }
    const localX: number = this.tapLocalX;
    const localY: number = this.tapLocalY;
    const startX: number = this.tapStartX;
    const startY: number = this.tapStartY;
    const moved: number = event.changedTouches.length > 0
      ? Math.abs(event.changedTouches[0].windowX - startX) + Math.abs(event.changedTouches[0].windowY - startY)
      : 0;
    const elapsed: number = Date.now() - this.tapStartTime;
    this.tapStartTime = 0;
    if (moved > 12 || this.viewerOpen) {
      return;
    }
    if (elapsed >= 600) {
      // 长按：只处理图片（打开大图，保存入口在查看器里）。
      this.handleBodyTap(localX, localY);
      return;
    }
    if (elapsed > 300) {
      return;
    }
    this.handleBodyTap(localX, localY);
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
    this.readScrollY(this.webController, article.id, MODE_WEB);
  }

  private persistReaderProgress(): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || this.readerHtml.length === 0 || this.finished) {
      return;
    }
    this.readScrollY(this.readerController, article.id, MODE_READER);
  }

  /** 读一次文档位置（px + 比例）并写回本地库。 */
  private readScrollY(controller: webview.WebviewController, articleId: string, mode: string): void {
    controller.runJavaScript(readPositionScript(), (err: BusinessError, value: string) => {
      if (err) {
        hilog.warn(DOMAIN, TAG, 'read scroll position failed: %{public}d', err.code);
        return;
      }
      if (value.indexOf('|') < 0) {
        return;
      }
      if (this.finished && feedViewModel.currentArticle()?.id === articleId) {
        return;
      }
      const position: ReaderPosition = parsePosition(value);
      this.progressQueue.remember(articleId, mode, position);
      feedViewModel.saveProgress(articleId, position.y, position.ratio);
    });
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
    } else if (this.sheetMode === 'tags') {
      TagSheetView({
        selectedTagIds: this.tagIds(),
        onConfirm: (ids: string[]): void => {
          this.applyTagSelection(ids);
          this.closeSheet();
        }
      })
    } else if (this.sheetMode === 'sources') {
      SourcesPanelView({
        sources: this.groupSources,
        currentId: this.cur().id,
        onOpen: (source: GroupSource): void => this.openSource(source)
      })
    } else if (this.sheetMode === 'share') {
      ShareSheetView({
        ability: this.hostContext(),
        onClose: (): void => {
          this.closeSheet();
          shareViewModel.close();
        }
      })
    } else if (this.sheetMode === 'translate') {
      TranslateSheetView({
        onOpenSettings: (): void => {
          translationViewModel.close();
          this.closeSheet();
          this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_TRANSLATE_SETTINGS, ''));
        }
      })
    } else if (this.sheetMode === 'toc') {
      TocSheetView({
        toc: this.toc,
        onGoto: (index: number): void => this.gotoHeading(index)
      })
    } else {
      ReadSheetView({
        webMode: this.viewMode === MODE_WEB,
        onApply: (): void => this.applyTypography()
      })
    }
  }

  /** 打开目录：先从正文里采集标题，没有标题就给即时提示。 */
  private openToc(): void {
    this.bodyController().runJavaScript(collectTocScript())
      .then((raw: string) => {
        this.toc = this.parseToc(raw);
        if (this.toc.length === 0) {
          Toast.show($r('app.string.toc_empty'));
          return;
        }
        this.openSheet('toc');
      })
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'collect toc failed: %{public}d', err.code);
      });
  }

  /** 目录面板点一条：滚到对应标题并收起面板。 */
  private gotoHeading(index: number): void {
    this.bodyController().runJavaScript(gotoHeadingScript(index)).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'goto heading failed: %{public}d', err.code);
    });
    this.closeSheet();
  }

  /** runJavaScript 回传可能再包一层引号；解析失败按「没有目录」处理。 */
  private parseToc(raw: string): TocEntry[] {
    let text: string = raw.trim();
    if (text.length > 1 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1).replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    }
    const result: TocEntry[] = [];
    try {
      const list: TocRaw[] = JSON.parse(text) as TocRaw[];
      for (let i = 0; i < list.length; i += 1) {
        const item: TocRaw = list[i];
        const label: string = typeof item.text === 'string' ? item.text : '';
        if (label.length === 0) {
          continue;
        }
        const level: number = typeof item.level === 'number' ? item.level : 2;
        const index: number = typeof item.index === 'number' ? item.index : i;
        result.push(new TocEntry(level, label, index));
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'parse toc failed');
      return [];
    }
    return result;
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
                    .fontColor(themePalette.accent())
                    .onClick(() => {
                      this.closeSheet();
                      this.gotoHighlight(item);
                    })
                  Text($r('app.string.hl_action_note'))
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor(themePalette.accent())
                    .onClick(() => {
                      this.openHighlightEditor(item.id);
                    })
                  Text($r('app.string.hl_action_color'))
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor(themePalette.accent())
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

      Stack({ alignContent: Alignment.End }) {
        TextInput({ text: this.noteDraft, placeholder: $r('app.string.hl_note_hint') })
          .type(InputType.Normal)
          .fontSize($r('app.float.font_size_body'))
          .width('100%')
          .padding({ left: $r('app.float.input_clear_text_inset'), right: $r('app.float.input_clear_inset') })
          .onChange((value: string) => {
            this.noteDraft = value;
          })
        ClearInputButton({
          visible: this.noteDraft.length > 0,
          onClear: () => {
            this.noteDraft = '';
          }
        })
      }
      .width('100%')

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
          .backgroundColor(themePalette.fill())
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

  /**
   * 应用排版改动：Reader 模式原地替换文档里的 <style>（不重建文档，位置保持不变），
   * 网页原文模式只需重新注入覆盖样式（幂等）。
   */
  private applyTypography(): void {
    if (this.viewMode === MODE_READER && this.readerHtml.length > 0) {
      const topPad: number = this.readerTopPad();
      this.appliedTopPad = topPad;
      this.readerController
        .runJavaScript(readerStyleScript(topPad, this.contentBottomInsetVp()))
        .catch((err: BusinessError) => {
          // 文档还没就绪（或控制器失效）时注入会失败：退回整篇重建，保证排版最终生效。
          hilog.warn(DOMAIN, TAG, 'typography inject failed: %{public}d', err.code);
          this.loadReaderDocIntoWeb();
        });
      return;
    }
    if (this.viewMode === MODE_WEB) {
      const webTopPad: number = this.readerTopPad();
      this.appliedTopPad = webTopPad;
      readerStyle.apply(this.webController, webTopPad, this.contentBottomInsetVp());
    }
  }

  /** 当前底栏高度：普通模式是 HdsTabs，查找模式是双行面板。 */
  private barStripHeight(): number {
    return safeArea.bottomInsetVp + (this.findOpen ? FIND_BAR_HEIGHT_VP : CommonConstants.TAB_BAR_HEIGHT_VP);
  }

  @Builder
  FloatingBar() {
    if (this.hasArticle()) {
      if (this.findOpen) {
        this.FindBar()
      } else {
        ArticleActionBar({
        canPrev: feedViewModel.prevArticleId().length > 0,
        canNext: feedViewModel.nextArticleId().length > 0,
        canNextUnread: feedViewModel.nextUnreadId().length > 0,
        starred: this.cur().starred,
        webMode: this.viewMode === MODE_WEB,
        accent: themePalette.accent(),
        menuProvider: (): MenuSpec => this.actionsMenuSpec(this.cur()),
        onPrev: (): void => {
          this.openRelative(feedViewModel.prevArticleId(), -1);
        },
        onNext: (): void => this.openRelative(feedViewModel.nextArticleId()),
        onNextUnread: (): void => this.openRelative(feedViewModel.nextUnreadId()),
        onFont: (): void => this.openSheet('read'),
        onMode: (): void => this.switchMode(),
        onStar: (): void => feedViewModel.toggleStar(this.cur().id),
        onTag: (): void => this.openTagSheet()
        })
      }
    }
  }

  /** 加载遮罩：不透明主题面板盖住 Web 默认白底，避免深色主题转场白闪。 */
  @Builder
  LoadingVeil() {
    Column() {
      LoadingProgress()
        .width($r('app.float.web_loading_size'))
        .height($r('app.float.web_loading_size'))
        .color(themePalette.accent())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.hm_web_surface'))
  }

  /** Reader 文档加载完成：收 loading、重放标注、恢复进度、预取下一篇。 */
  private onReaderPageEnd(): void {
    this.loading = false;
    this.logPageEndFallback(MODE_READER);
    const article: Article | undefined = feedViewModel.currentArticle();
    this.progressReadyAt = article !== undefined &&
      (article.progress > 0 || article.progressRatio > 0) ? Date.now() + 5200 : 0;
    this.startProgressPolling(this.readerController);
    this.readerController.runJavaScript(speechManualScrollScript()).catch(() => {
    });
    // 滚动实时上报（幂等）：进度条跟手更新，轮询只做兜底。
    this.readerController.runJavaScript(progressObserverScript()).catch(() => {
    });
    this.replayHighlights(this.readerController);
    this.syncReaderInset();
    if (this.consumePendingSearch()) {
      this.readerProgressRestored = true;
      this.schedulePrefetch();
      return;
    }
    this.restoreReaderProgress();
    this.schedulePrefetch();
  }

  /** 网页原文加载完成：注入排版、恢复进度，SPA 站点再抓一次 DOM 快照。 */
  private onWebPageEnd(): void {
    if (this.webFailed) {
      return;
    }
    this.loading = false;
    this.logPageEndFallback(MODE_WEB);
    const article: Article | undefined = feedViewModel.currentArticle();
    this.progressReadyAt = article !== undefined &&
      (article.progress > 0 || article.progressRatio > 0) ? Date.now() + 5200 : 0;
    const topPad: number = this.readerTopPad();
    this.appliedTopPad = topPad;
    readerStyle.apply(this.webController, topPad, this.contentBottomInsetVp());
    this.startProgressPolling(this.webController);
    // 网页原文：同样注入滚动上报（站点自定义滚动容器也能拿到 window 滚动事件）。
    this.webController.runJavaScript(progressObserverScript()).catch(() => {
    });
    this.replayHighlights(this.webController);
    if (this.consumePendingSearch()) {
      this.webProgressRestored = true;
    } else {
      this.restoreWebProgress();
    }
    this.schedulePrefetch();
    this.scheduleWebSnapshot();
  }

  /** Reader 模式：结构化正文文档（提取失败时展示重试 / 退网页原文）。 */
  @Builder
  ReaderBody() {
    if (this.hasArticle()) {
      Stack() {
        if (this.readerHtml.length > 0) {
          ReaderBodyView({
            html: this.readerHtml,
            controller: this.readerController,
            speechBridge: this.speechScrollBridge,
            progressBridge: this.progressBridge,
            highlightBridge: this.hlBridge,
            swipeDistance: SWIPE_DISTANCE_VP,
            onKey: (event: KeyEvent): boolean => this.handleShortcut(event),
            onSelection: (text: string): void => {
              if (this.selectedText !== text) {
                this.selectedText = text;
              }
            },
            onTouchEvent: (event: TouchEvent): void => this.handleBodyTouch(event),
            onAttached: (): void => this.loadReaderDocIntoWeb(),
            onPageEnd: (): void => this.onReaderPageEnd(),
            onFirstPaint: (ms: number): void => this.logFirstPaint(ms, MODE_READER),
            onOverScroll: (event: OnOverScrollEvent): void => {
              if (Math.abs(event.yOffset) >= OVERSCROLL_TRIGGER_VP) {
                this.checkReachedBottom(this.readerController);
              }
            },
            onLoadIntercept: (event: OnLoadInterceptEvent): boolean => this.handleLinkIntercept(event),
            onWindowNew: (event: OnWindowNewEvent): void => this.handleNewWindow(event),
            onPanStart: (event: GestureEvent): void => {
              this.panStartX = event.fingerList.length > 0 ? event.fingerList[0].globalX : -1;
            },
            onPanEnd: (event: GestureEvent): void => this.onHorizontalPan(event.offsetX)
          })
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
        WebBodyView({
          link: this.cur().link,
          controller: this.webController,
          progressBridge: this.progressBridge,
          highlightBridge: this.hlBridge,
          swipeDistance: SWIPE_DISTANCE_VP,
          onLoadIntercept: (event: OnLoadInterceptEvent): boolean => this.handleLinkIntercept(event),
          onWindowNew: (event: OnWindowNewEvent): void => this.handleNewWindow(event),
          onMainFrameError: (): void => this.failWeb(),
          onSelection: (text: string): void => {
            if (this.selectedText !== text) {
              this.selectedText = text;
            }
          },
          onTouchEvent: (event: TouchEvent): void => this.handleBodyTouch(event),
          onPageEnd: (): void => this.onWebPageEnd(),
          onPageBegin: (): void => this.beginDocLoad(),
          onFirstPaint: (ms: number): void => this.logFirstPaint(ms, MODE_WEB),
          onOverScroll: (event: OnOverScrollEvent): void => {
            if (Math.abs(event.yOffset) >= OVERSCROLL_TRIGGER_VP) {
              this.checkReachedBottom(this.webController);
            }
          },
          onPanStart: (event: GestureEvent): void => {
            this.panStartX = event.fingerList.length > 0 ? event.fingerList[0].globalX : -1;
          },
          onPanEnd: (event: GestureEvent): void => this.onHorizontalPan(event.offsetX)
        })
        if (this.loading) {
          this.LoadingVeil()
        }
        if (this.webFailed) {
          this.WebErrorState()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.hm_web_surface'))
      .clip(true)
    }
  }

  /** 网页原文不可用时给出明确的恢复路径。 */
  @Builder
  WebErrorState() {
    Column({ space: $r('app.float.space_m') }) {
      Text($r('app.string.article_web_load_failed'))
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .textAlign(TextAlign.Center)
      Row({ space: $r('app.float.space_s') }) {
        Button($r('app.string.action_retry'))
          .onClick(() => { this.retryWeb(); })
        Button($r('app.string.action_open_browser'))
          .onClick(() => { this.openInBrowser(this.cur()); })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.hm_web_surface'))
  }

  /** 提取正文兜底：feed 里能拿到的纯文本 + 原文链接。 */
  @Builder
  TextBody() {
    if (this.hasArticle()) {
      Scroll(this.scroller) {
        Column({ space: $r('app.float.space_m') }) {
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
                .fontColor(themePalette.accent())
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
          bottom: this.contentBottomInsetVp()
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

  /** 底部双行查找面板：输入与操作分行，暂时替换阅读工具栏。 */
  @Builder
  FindBar() {
    Row() {
      Column({ space: $r('app.float.space_xs') }) {
      Row({ space: $r('app.float.space_s') }) {
        TextInput({ text: this.findQuery, placeholder: $r('app.string.find_hint') })
          .id('articleFindInput')
          .type(InputType.Normal)
          .fontSize($r('app.float.font_size_caption'))
          .height(FIND_CONTROL_HEIGHT_VP)
          .layoutWeight(1)
          .focusable(this.findInputActivated)
          .onClick(() => {
            if (!this.findInputActivated) {
              this.findInputActivated = true;
              setTimeout(() => {
                if (!this.findOpen || !this.findInputActivated) {
                  return;
                }
                Keyboard.requestFocus('articleFindInput');
              }, 80);
            }
          })
          .onChange((value: string) => {
            this.applyFind(value);
          })

        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([themePalette.accent()])
          .width(FIND_CONTROL_HEIGHT_VP)
          .height(FIND_CONTROL_HEIGHT_VP)
          .accessibilityText($r('app.string.a11y_find_close'))
          .onClick(() => {
            this.closeFind();
          })
      }
      .width('100%')
      .height(FIND_CONTROL_HEIGHT_VP)

      Row() {
        Text(this.findQuery.length === 0 ? '' : (this.findCount > 0
          ? $r('app.string.find_count', this.findIndex + 1, this.findCount)
          : $r('app.string.find_none')))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)
          .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.chevron_up'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([this.findCount > 0 ? themePalette.accent() : $r('app.color.hm_text_secondary')])
          .width(FIND_CONTROL_HEIGHT_VP)
          .height(FIND_CONTROL_HEIGHT_VP)
          .accessibilityText($r('app.string.a11y_find_prev'))
          .enabled(this.findCount > 0)
          .onClick(() => {
            this.stepFind(-1);
          })

        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([this.findCount > 0 ? themePalette.accent() : $r('app.color.hm_text_secondary')])
          .width(FIND_CONTROL_HEIGHT_VP)
          .height(FIND_CONTROL_HEIGHT_VP)
          .accessibilityText($r('app.string.a11y_find_next'))
          .enabled(this.findCount > 0)
          .onClick(() => {
            this.stepFind(1);
          })
      }
      .width('100%')
      .height(FIND_CONTROL_HEIGHT_VP)
      }
      .width('100%')
      .height(FIND_BAR_HEIGHT_VP)
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l'),
        top: $r('app.float.space_s'), bottom: $r('app.float.space_s') })
      .backgroundColor($r('app.color.hm_card_background'))
      .borderRadius($r('app.float.radius_card'))
    }
    .width('100%')
    .height(this.barStripHeight())
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l'),
      bottom: safeArea.bottomInsetVp })
  }

  /**
   * 正文纯文本长度（字符）。
   * 优先用落库的 plainText；缺失时用当前正文现算，但对内联过大图（base64）的文档跳过，
   * 避免每次 build 都去正则扫几 MB 的字符串。
   */
  private readerBodyChars(): number {
    const plain: string = this.cur().plainText;
    if (plain.length > 0) {
      return plain.trim().length;
    }
    if (this.readerHtml.length > 0 && this.readerHtml.length < 262144) {
      return toPlainText(this.readerHtml).trim().length;
    }
    return 0;
  }

  /**
   * 是否提示「这段可能只是摘要」：正文本就短、文章有外链、用户还没关掉过这个提示。
   * 典型场景：Show HN 这类投稿，feed 自带正文只有一段介绍，真实内容在需要 JS 渲染的站点上，
   * 静态提取拿不到（例如 wikihack.netlify.app 的 HTML 只有 <div id="root"></div>）。
   */
  private shouldHintShortBody(): boolean {
    if (this.viewMode !== MODE_READER || this.shortBodyHintClosed || !this.hasArticle()) {
      return false;
    }
    const link: string = this.cur().link;
    if (!/^https?:\/\//i.test(link)) {
      return false;
    }
    const chars: number = this.readerBodyChars();
    return chars > 0 && chars < SHORT_BODY_HINT_CHARS;
  }

  /** 提示里的动作：切到网页原文（真实内容常由页面 JS 渲染，只有网页原文能看到）。 */
  private openWebForShortBody(): void {
    this.shortBodyHintClosed = true;
    if (this.viewMode === MODE_READER) {
      this.switchMode();
    }
  }

  /** 正文偏短提示条：贴在底栏上方，说明可能只取到摘要，并给一键切网页原文的入口。 */
  @Builder
  ShortBodyHint() {
    if (this.shouldHintShortBody()) {
      Row({ space: $r('app.float.space_xs') }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([$r('app.color.hm_text_secondary')])
        Text($r('app.string.reader_short_body_hint'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Button($r('app.string.article_mode_web'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(themePalette.accent())
          .padding({ left: $r('app.float.space_xxs'), right: $r('app.float.space_xxs') })
          .onClick(() => {
            this.openWebForShortBody();
          })
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .padding($r('app.float.space_xxs'))
          .accessibilityText($r('app.string.dialog_cancel'))
          .onClick(() => {
            this.shortBodyHintClosed = true;
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

  /** 播客迷你播放条：底部浮层，支持暂停 / 继续、±15s、倍速、上一首 / 下一首、停止。 */
  @Builder
  MediaBar() {
    if (mediaPlayerService.status !== MEDIA_IDLE) {
      Column({ space: $r('app.float.space_xxs') }) {
        Row({ space: $r('app.float.space_xs') }) {
          SymbolGlyph($r('sys.symbol.headphones'))
            .fontSize($r('app.float.icon_size_small'))
            .fontColor([themePalette.accent()])
          Column({ space: $r('app.float.space_xxs') }) {
            Text(mediaPlayerService.title)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(mediaPlayerService.status === MEDIA_ERROR
              ? $r('app.string.media_error')
              : mediaPlayerService.feedTitle)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor(mediaPlayerService.status === MEDIA_ERROR
                ? $r('app.color.hm_danger') : $r('app.color.hm_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Button(mediaPlayerService.status === MEDIA_PLAYING
            ? $r('app.string.media_pause') : $r('app.string.media_resume'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(themePalette.accent())
            .padding({ left: $r('app.float.space_xxs'), right: $r('app.float.space_xxs') })
            .enabled(mediaPlayerService.status !== MEDIA_LOADING)
            .onClick(() => {
              mediaPlayerService.toggle();
            })

          Button($r('app.string.media_stop'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding({ left: $r('app.float.space_xxs'), right: $r('app.float.space_xxs') })
            .onClick(() => {
              mediaPlayerService.stop();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: $r('app.float.space_xxs') }) {
          Button('-15')
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding({ left: $r('app.float.space_xxs'), right: $r('app.float.space_xxs') })
            .accessibilityText($r('app.string.media_rewind'))
            .onClick(() => {
              mediaPlayerService.seekBy(-15);
            })
          Button('+15')
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding({ left: $r('app.float.space_xxs'), right: $r('app.float.space_xxs') })
            .accessibilityText($r('app.string.media_forward'))
            .onClick(() => {
              mediaPlayerService.seekBy(15);
            })
          Button(`${mediaPlayerService.speed.toFixed(1)}×`)
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding({ left: $r('app.float.space_xxs'), right: $r('app.float.space_xxs') })
            .accessibilityText($r('app.string.media_speed'))
            .onClick(() => {
              mediaPlayerService.cycleSpeed();
            })
          Button('‹')
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_body'))
            .fontColor(themePalette.accent())
            .padding({ left: $r('app.float.space_xxs'), right: $r('app.float.space_xxs') })
            .accessibilityText($r('app.string.media_previous'))
            .onClick(() => {
              mediaPlayerService.prev();
            })
          Button('›')
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_body'))
            .fontColor(themePalette.accent())
            .padding({ left: $r('app.float.space_xxs'), right: $r('app.float.space_xxs') })
            .accessibilityText($r('app.string.media_next'))
            .onClick(() => {
              mediaPlayerService.next();
            })
          Blank()
          Text(formatDuration(mediaPlayerService.positionSeconds) + ' / ' +
            formatDuration(mediaPlayerService.durationSeconds))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
          if (mediaPlayerService.queueSize > 1) {
            Text((mediaPlayerService.queueIndex + 1).toString() + '/' +
              mediaPlayerService.queueSize.toString())
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .margin({ left: $r('app.float.space_xs') })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
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
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 朗读迷你条：朗读中出现在底栏上方，可暂停 / 继续、切换语速、停止。 */
  @Builder
  SpeechBar() {
    if (this.speaking) {
      Column({ space: $r('app.float.space_xxs') }) {
        Row({ space: $r('app.float.space_xxs') }) {
          SymbolGlyph($r('sys.symbol.speaker'))
            .fontSize($r('app.float.icon_size_small'))
            .fontColor([themePalette.accent()])

          Column({ space: $r('app.float.space_xxs') }) {
            Text(this.speechPaused ? $r('app.string.speech_paused') : $r('app.string.speech_running'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${this.speechIndex + 1}/${this.speechTotal}`)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button(`${this.speechSpeed.toFixed(1)}×`)
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding({ left: $r('app.float.space_xxs'), right: $r('app.float.space_xxs') })
            .onClick(() => {
              this.cycleSpeechSpeed();
            })

          Button(this.speechPaused ? $r('app.string.action_resume_speech') : $r('app.string.action_pause_speech'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(themePalette.accent())
            .padding({ left: $r('app.float.space_xxs'), right: $r('app.float.space_xxs') })
            .onClick(() => {
              this.toggleSpeechPause();
            })

          Button($r('app.string.action_stop_speech'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(themePalette.accent())
            .padding({ left: $r('app.float.space_xxs'), right: $r('app.float.space_xxs') })
            .onClick(() => {
              readerSpeech.stop();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (!this.speechFollow && this.speechSegmentId >= 0) {
          Button($r('app.string.action_return_to_speech'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(themePalette.accent())
            .onClick(() => {
              this.returnToSpeech();
            })
        }
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
      .alignItems(HorizontalAlign.Center)
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
          .fontColor(themePalette.accent())
          .onClick(() => {
            this.addHighlight();
          })

        Button($r('app.string.translate_action_selection'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(themePalette.accent())
          .onClick(() => {
            this.translateSelected();
          })

        Button($r('app.string.action_copy'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(themePalette.accent())
          .onClick(() => {
            this.copySelection();
          })

        Button($r('app.string.action_share_selection'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(themePalette.accent())
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
        bottom: $r('app.float.space_s')
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
          .backgroundColor(themePalette.fill())
          .borderRadius($r('app.float.read_progress_height'))
      }
      .width('100%')
      .height($r('app.float.read_progress_height'))
    }
  }

  /** 长文阅读时在底栏上方显示明确的百分比。 */
  @Builder
  ProgressBadge() {
    if (this.hasArticle() && this.progressRatio > 0.005 && this.progressRatio < 1) {
      Row() {
        Text($r('app.string.article_read_progress', Math.round(this.progressRatio * 100)))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .padding({ left: $r('app.float.space_s'), right: $r('app.float.space_s'),
            top: $r('app.float.space_xxs'), bottom: $r('app.float.space_xxs') })
          .backgroundColor($r('app.color.hm_card_background'))
          .borderRadius($r('app.float.radius_card'))
      }
      .width('100%')
      .padding({ right: $r('app.float.space_l'), bottom: $r('app.float.space_xxs') })
      .margin({ bottom: this.barStripHeight() })
      .justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.None)
    }
  }

  /** 一个标签 chip（点击进入选择器，可快速增删）。 */
  @Builder
  TagChip(tag: TagWithCount) {
    Text(tag.name)
      .fontSize($r('app.float.font_size_caption'))
      .fontColor(themePalette.accent())
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .constraintSize({ maxWidth: 160 })
      .height($r('app.float.value_chip_height'))
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
      .margin({ right: $r('app.float.space_xs'), bottom: $r('app.float.space_xxs') })
      .backgroundColor($r('app.color.hm_value_chip_background'))
      .borderRadius($r('app.float.radius_chip'))
      .onClick(() => {
        this.openTagSheet();
      })
  }

  /**
   * 标题下方的标签条：已有标签横排（可左右滑动）。
   * 「+ 添加标签」已移到悬浮底栏（见 TagAction），标签条只在有内容时才占位。
   * 正文顶部按 bodyTopPadding() 一起让位（状态栏 + 标题栏 + 本条的 44vp），所以不会压住正文首行。
   */
  @Builder
  TagChips() {
    if (this.hasArticle() && this.hasTopChips()) {
      Row({ space: $r('app.float.space_xs') }) {
        if (this.articleTags.length > 0) {
          // 横排、可左右滑动：标签多时不换行（换行会超出预留高度压住正文）。
          Scroll() {
            Row() {
              ForEach(this.articleTags, (tag: TagWithCount) => {
                this.TagChip(tag)
              }, (tag: TagWithCount) => tag.id + '_' + tag.name)
            }
            .height($r('app.float.value_chip_height'))
            .alignItems(VerticalAlign.Center)
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .layoutWeight(1)
          .height($r('app.float.value_chip_height'))
          .align(Alignment.Start)
        } else {
          Blank()
        }

        // 媒体标识：播客带时长，视频标类型；点击可直接播放 / 打开。
        if (this.cur().enclosures.length > 0) {
          Text(this.mediaChipText(this.cur()))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(themePalette.accent())
            .maxLines(1)
            .height($r('app.float.value_chip_height'))
            .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
            .margin({ right: $r('app.float.space_xs') })
            .backgroundColor($r('app.color.hm_value_chip_background'))
            .borderRadius($r('app.float.radius_chip'))
            .accessibilityText(this.audioOf(this.cur()) !== undefined
              ? $r('app.string.media_audio_label') : $r('app.string.media_video_label'))
            .onClick(() => {
              this.mediaChipAction();
            })
        }

        // 跨源合并文章：来源数 chip（点击展开全部来源）。单来源时不出现，界面保持现状。
        if (this.merged()) {
          Text($r('app.string.dedupe_source_count', this.groupSources.length))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(themePalette.accent())
            .maxLines(1)
            .height($r('app.float.value_chip_height'))
            .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
            .margin({ right: $r('app.float.space_xs') })
            .backgroundColor($r('app.color.hm_value_chip_background'))
            .borderRadius($r('app.float.radius_chip'))
            .accessibilityText($r('app.string.dedupe_sources_title'))
            .onClick(() => {
              this.openSourceSheet();
            })
        }
      }
      .width('100%')
      .height(TAG_STRIP_VP)
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
      .alignItems(VerticalAlign.Top)
    }
  }

  /**
   * 标题下方标签条是否有内容：标签 / 媒体标识 / 来源数任一存在时才占位。
   * 都没有时（绝大多数单来源、无标签文章）不再白留一条高度给已移走的「+」。
   */
  private hasTopChips(): boolean {
    return this.articleTags.length > 0
      || this.cur().enclosures.length > 0
      || this.merged();
  }

  /**
   * 正文容器顶部让位：0（正文铺到屏幕最顶端，状态栏 + 标题栏都是叠加层）。
   *
   * 首屏首行由文档内边距让位（见 readerTopPad），滚动时正文从状态栏、标题栏下方穿过；
   * 顶部那条模糊背板（见 TopBlurBand）负责把穿过的文字压住，标题始终可读。
   */
  private bodyTopPadding(): number {
    return 0;
  }

  /**
   * 顶部背板：覆盖「状态栏 + 标题栏（+ 标签条）」那一条的模糊 + 半透明遮罩。
   *
   * 只做底衬 —— 标题文字 / 返回键仍由 HDS 原生标题栏绘制，这里不加任何控件。
   * 正文滚动到这一条时被模糊压住，标题任何时刻都可读（ArkWeb 画面不参与原生材质采样，
   * 所以这里用 ArkUI 的背景模糊自己做一层）。
   */
  @Builder
  TopScrim() {
    Column() {
      Row()
        .width('100%')
        .height(safeArea.contentTopInsetVp + (this.hasTopChips() ? TAG_STRIP_VP : 0))
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 正文铺满整屏（含状态栏 / 标题栏下方），首屏首行由文档内边距让位（见 readerTopPad）；
      // 切文时由 playSwitchAnimation 给一层轻量位移 + 淡入。
      Column() {
        this.BodySwitch()
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.bodyTopPadding() })
      .backgroundColor($r('app.color.hm_web_surface'))
      .translate({ x: this.bodyShift })
      .opacity(this.bodyAlpha)

      // 顶部背板：状态栏 + 标题栏（+ 标签条）那一条的模糊/遮罩，正文从下面穿过时被压住。
      // 只做底衬，标题与返回键仍由 HDS 原生标题栏绘制（不在上面再画一层栏）。
      this.TopScrim()

      Column() {
        Blank()
          .hitTestBehavior(HitTestMode.None)
        this.ProgressBadge()
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      // 底部浮层：短正文提示 + 朗读条 + 选段条，都排在「底栏上方」那一段（padding 让出底栏高度）
      Column() {
        Blank()
          .hitTestBehavior(HitTestMode.None)
        this.ShortBodyHint()
        this.MediaBar()
        this.SpeechBar()
        this.SelectionBar()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.Center)
      // 让出底栏那一条：这些浮条贴在底栏之上，不再和悬浮操作栏重叠（重叠会被底栏盖住）。
      .padding({ bottom: this.barStripHeight() })
      // 这里必须是 Transparent 而不是 None：None 会让整层（含里面的提示卡 / 播放条）不参与命中，
      // 点按会穿透到正文，表现为「提示条上的按钮点不动」。
      .hitTestBehavior(HitTestMode.Transparent)

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

      // 标签条层：标题栏下方一条，chip / 「+」自己吃手势，其余区域透传给正文。
      Column() {
        Row()
          .width('100%')
          .height(safeArea.contentTopInsetVp)
        this.TagChips()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .hitTestBehavior(HitTestMode.None)

      /**
       * 底栏：必须画在所有「铺满整页」的浮层（进度徽标 / 朗读条 / 进度线 / 标签条）之上，
       * 只让图片全屏查看器压在它上面。
       *
       * 为什么顺序要紧：这些浮层即使自身是 HitTestMode.None / Transparent，层里铺满全屏的
       * Blank / Row 占位仍会参与触摸测试，而它们和底栏是同一个 Stack 的兄弟节点 —— 命中判定先落在
       * 上面那层，底栏整棵子树就再也收不到 touch（表现为：底栏图标全部点不动，只能透传给正文）。
       * 所以底栏放在浮层之后、查看器之前，是这里唯一正确的层次。
       *
       * 底栏常驻：不随点按 / 滚动收起，保证任何时候都能操作。
       */
      Column() {
        this.FloatingBar()
      }
      .width('100%')
      .height(this.barStripHeight())
      .clip(true)

      // 图片全屏查看器：盖在最上层，自带黑色背景与保存控件。
      if (this.viewerOpen && this.viewerSrc.length > 0) {
        ReaderImageViewer({
          src: this.viewerSrc,
          referer: this.cur().link,
          onClose: () => {
            this.viewerOpen = false;
            this.viewerSrc = '';
          },
          onSave: (src: string) => {
            this.saveImage(src);
          }
        })
      }

      // 半模态统一宿主：系统材质 + 三挡高度固定在 AppSheet 内，内容仍由本页 SheetContent 分派。
      AppSheet({
        visible: this.showSheet,
        initialSize: this.sheetMode === 'read' || this.sheetMode === 'tags' || this.sheetMode === 'share' ||
          this.sheetMode === 'translate'
          ? SheetSize.LARGE
          : SheetSize.MEDIUM,
        onDismiss: () => {
          const mode: string = this.sheetMode;
          this.showSheet = false;
          this.sheetMode = '';
          // 面板被下滑关闭时也要清空分享上下文，避免下次打开闪出上一次的内容。
          if (mode === 'share') {
            shareViewModel.close();
          }
          if (mode === 'translate') {
            translationViewModel.close();
          }
        }
      }) {
        this.SheetContent()
      }
    }
    .width('100%')
    .height('100%')
    // 详情页键盘快捷键：页面根节点默认持焦；点击正文等子组件后仍会向上冒泡到这里。
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent): boolean => {
      return this.handleShortcut(event);
    })
    // 旋转 / 折叠 / 分栏后状态栏高度会变：文档里的顶部让位要按新值重新注入。
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.scheduleReaderInset();
    })
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
