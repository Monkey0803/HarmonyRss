/*
 * ArticleContentService.ets — Reader 正文的获取编排（缓存优先 → 抓原文 → 提取 → 落库）。
 *
 * 数据来源优先级：
 *   1. 本地库已有的 reader_html（离线可读，命中即返回）；
 *   2. feed 自带的结构化正文 contentHtml —— 只有「够长 / 段落够多」才算完整正文（FeedBodyKind.FULL），
 *      一句简介（SUMMARY）不再直接当正文，而是联网抓原文后作为顶部摘要卡片；
 *   3. 联网抓 article.link 的 HTML 再提取。
 * 抓取失败 / 提取为空 / 只是 SPA 空壳时抛出 FeedFetchError，由上层决定退网页原文。
 * 网页原文渲染完成后，调用方还可把 DOM 交回 adoptRenderedHtml() 再提取一次（SPA 兜底）。
 *
 * 三级缓存标记（补图不阻塞正文首屏）：
 *   hrv9t：文本已就绪，失败图片下次联网打开可重试；
 *   hrv9p：图片预算或格式受限，正文可离线读，部分图片仍需联网；
 *   hrv9：正文与所含图片都已缓存。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { articleStore } from './ArticleStore';
import { toPlainText } from '../common/utils/HtmlText';
import { extractReadable, feedBodyKind } from './Readability';
import {
  isReaderPlaceholder,
  isSpaShellHtml,
  ReaderNeedsJsError,
  ReaderPlaceholderError
} from './ReaderContentGuard';
import { imageCache, InlineImagesResult } from './ImageCache';
import { ReaderBudget } from './ReaderBudget';
import { NetworkStatus } from './NetworkStatus';
import {
  ReaderState,
  RssConstants,
  ReaderConstants,
  FeedBodyKind,
  FeedError,
  FeedFetchError
} from '../common/constants/RssConstants';
import { FullTextMode } from '../common/constants/SettingsConstants';
import {
  HttpError,
  HttpErrorKind,
  HttpOptions,
  HttpResponse,
  httpClient,
  setConditionalHeaders
} from './HttpClient';

const DOMAIN: number = 0x0000;
const TAG: string = 'ArticleContentService';

/**
 * Reader HTML 版本标记（存在正文片段开头）。
 * 缓存命中要求带标记：提取规则升级时递增版本号，旧缓存按「未命中」处理 ——
 * 打开文章时用新规则重新提取（离线仍回退到旧缓存，不阻断阅读）。
 * hrv9：校验图片真实格式，并区分完整缓存与预算受限的部分缓存。
 */
const READER_MARKER: string = '<!--hrv9-->';
/**
 * 「文本就绪」标记：正文可立即展示，图片仍是远程链接。
 * 联网时后台串行补图，成功后再升级为 READER_MARKER。
 */
const READER_MARKER_TEXT: string = '<!--hrv9t-->';
/** 已尽力缓存，但仍有超出单篇预算的远程图片；下次打开不重复下载。 */
const READER_MARKER_PARTIAL: string = '<!--hrv9p-->';
const LEGACY_READER_MARKER: string = '<!--hrv8-->';
const LEGACY_READER_MARKER_TEXT: string = '<!--hrv8t-->';
/** 首屏渲染完成后再开始补图（避免与 Web 首次加载抢带宽与主线程）。 */
const INLINE_DELAY_MS: number = 2000;
/** 正文顶部「feed 简介」卡片的类名（配 ReaderDocument 里的 CSS）。 */
export const FEED_SUMMARY_CLASS: string = 'hr-feed-summary';

/** 去掉缓存标记，取出正文片段。 */
function readerBodyOf(cached: string): string {
  const markers: string[] = [READER_MARKER, READER_MARKER_PARTIAL, READER_MARKER_TEXT,
    LEGACY_READER_MARKER, LEGACY_READER_MARKER_TEXT];
  for (let i = 0; i < markers.length; i += 1) {
    if (cached.startsWith(markers[i])) {
      return cached.substring(markers[i].length);
    }
  }
  return cached;
}

/**
 * feed 自带的简介做成正文顶部的摘要卡片。
 * 真实页面抓到后，把「一句话投稿说明」作为引子保留，读者既知道这是什么，也能往下读全文。
 */
export function feedSummaryCard(summaryHtml: string): string {
  const body: string = summaryHtml.trim();
  return body.length > 0 ? '<aside class="' + FEED_SUMMARY_CLASS + '">' + body + '</aside>' : '';
}

/** 网络失败保留重试入口；预算受限只标为部分缓存；全数落本地才标完整。 */
export function readerImageCacheMarker(remainingRemote: number, retryable: number,
  budgetRejected: boolean): string {
  if (retryable > 0) {
    return READER_MARKER_TEXT;
  }
  if (remainingRemote > 0 || budgetRejected) {
    return READER_MARKER_PARTIAL;
  }
  return READER_MARKER;
}

/** v8 缓存保留已内联图片；若仍有远程图，进入待补全状态而不重新抓整篇。 */
export function upgradeLegacyReaderCache(cached: string): string {
  let body: string = '';
  if (cached.startsWith(LEGACY_READER_MARKER)) {
    body = cached.substring(LEGACY_READER_MARKER.length);
  } else if (cached.startsWith(LEGACY_READER_MARKER_TEXT)) {
    body = cached.substring(LEGACY_READER_MARKER_TEXT.length);
  } else {
    return cached;
  }
  const hasRemote: boolean = /<img\b[^>]*\bsrc="https?:/i.test(body);
  return (hasRemote ? READER_MARKER_TEXT : READER_MARKER) + body;
}

/** 统一网络错误 → 抓取错误码（超时与其它网络故障区分开）。 */
function classifyRequestError(err: Object): FeedError {
  if (err instanceof HttpError) {
    return err.kind === HttpErrorKind.TIMEOUT ? FeedError.TIMEOUT : FeedError.NETWORK_ERROR;
  }
  return FeedError.NETWORK_ERROR;
}

/** 从异常里取可展示的描述。 */
function messageOf(err: Object): string {
  const error: Error = err as Error;
  return error.message !== undefined && error.message.length > 0 ? error.message : 'network failed';
}

/** 延时（毫秒）。 */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

/** 正文页抓取结果：notModified 为 true 时 html 为空（服务端说「没变」）。 */
export class PageFetch {
  readonly html: string;
  readonly notModified: boolean;
  readonly etag: string;
  readonly lastModified: string;

  constructor(html: string, notModified: boolean, etag: string, lastModified: string) {
    this.html = html;
    this.notModified = notModified;
    this.etag = etag;
    this.lastModified = lastModified;
  }
}

export class ArticleContentService {
  /** 同一篇文章的进行中提取任务（预取与打开撞车时复用同一个 Promise）。 */
  private inFlight: Map<string, Promise<string>> = new Map<string, Promise<string>>();
  /** 后台补图任务串行链：避免多篇同时下载图片抢带宽。 */
  private inlineQueue: Promise<void> = Promise.resolve();
  /** 按文章 ID 记录当前排队版本；相同正文的不同文章也各自补图。 */
  private inlineScheduled: Map<string, string> = new Map<string, string>();

  /**
   * 抓取正文页 HTML，带条件请求：带上 ETag / Last-Modified 时，页面没变服务端回 304，
   * 省掉一次整页下载（阅读器版本升级导致缓存同批次失效时，这一步能省下绝大多数流量）。
   */
  async fetchPage(url: string, etag: string, lastModified: string): Promise<PageFetch> {
    const header: Record<string, string> = {
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    };
    setConditionalHeaders(header, etag, lastModified);
    const options: HttpOptions = new HttpOptions();
    options.headers = header;
    options.connectTimeoutMs = RssConstants.CONNECT_TIMEOUT_MS;
    options.readTimeoutMs = RssConstants.READ_TIMEOUT_MS;
    let response: HttpResponse;
    try {
      response = await httpClient.getText(url, options);
    } catch (err) {
      throw new FeedFetchError(classifyRequestError(err), 'network: ' + messageOf(err));
    }
    if (response.status === 304) {
      return new PageFetch('', true, etag, lastModified);
    }
    if (response.status !== 200) {
      throw new FeedFetchError(FeedError.HTTP_ERROR, 'HTTP ' + response.status.toString());
    }
    const body: string = response.text;
    if (body.length === 0) {
      throw new FeedFetchError(FeedError.EMPTY_RESPONSE, 'empty html body');
    }
    const newEtag: string = response.header('etag');
    const newModified: string = response.header('last-modified');
    return new PageFetch(body, false,
      newEtag.length > 0 ? newEtag : etag,
      newModified.length > 0 ? newModified : lastModified);
  }

  /**
   * 确保文章拥有 Reader 正文；返回净化后的 HTML 片段（失败抛 FeedFetchError）。
   * 命中任一版本缓存时不发网络请求；文本版缓存（READER_MARKER_TEXT）会在联网时后台补图。
   * 会同步更新 article.readerHtml / readerState 并落库。
   *
   * 同一篇文章的并发请求（预取 + 用户打开）共用同一个 Promise，避免重复抓取与重复提取。
   *
   * @param fullTextMode 源生效的全文策略：
   *   auto   —— 有 feed 自带正文就用，否则联网抓原文（默认 / 历史行为）；
   *   always —— 强制联网抓原文（忽略 feed 自带正文）；
   *   never  —— 只用 feed 自带正文，不联网（没有正文则失败，由上层退网页原文）。
   */
  async ensureReaderHtml(article: Article, fullTextMode: string = FullTextMode.AUTO): Promise<string> {
    let cached: string = article.readerHtml;
    if (cached.length > 0 && isReaderPlaceholder(cached, article.link)) {
      // 旧版本曾将站点的脚本提示落库：先清掉，允许本次重新提取有效正文。
      hilog.info(DOMAIN, TAG, 'reader placeholder cache invalidated');
      cached = '';
      article.readerHtml = '';
      article.plainText = '';
      article.readerState = ReaderState.NONE;
      try {
        articleStore.setReaderHtml(article.id, '', '');
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'clear invalid reader cache failed: %{public}d', error.code);
      }
    }
    const upgraded: string = upgradeLegacyReaderCache(cached);
    if (upgraded !== cached) {
      cached = upgraded;
      this.persist(article, upgraded, article.plainText);
    }
    // 旧版本把 feed 的「一句简介」当正文缓存了（典型：Show HN 的投稿说明）：
    // 按未命中处理，重新联网抓真实页面。cached 仍作为抓取失败时的兜底，不清库。
    const staleSummary: boolean = this.isFeedSummaryCache(article, cached);
    if (staleSummary) {
      hilog.info(DOMAIN, TAG, 'reader cache holds feed summary, re-extracting');
    }
    if (!staleSummary && cached.length > 0 && cached.startsWith(READER_MARKER)) {
      article.readerState = ReaderState.READY;
      hilog.info(DOMAIN, TAG, 'reader cache hit (%{public}d chars)', cached.length);
      return cached;
    }
    if (!staleSummary && cached.length > 0 && cached.startsWith(READER_MARKER_PARTIAL)) {
      article.readerState = ReaderState.READY;
      hilog.info(DOMAIN, TAG, 'reader partial cache hit (%{public}d chars)', cached.length);
      return cached;
    }
    if (!staleSummary && cached.length > 0 && cached.startsWith(READER_MARKER_TEXT)) {
      // 文本已就绪：先把正文给到界面，图片交给后台补（不阻塞首屏）。
      article.readerState = ReaderState.READY;
      hilog.info(DOMAIN, TAG, 'reader text cache hit (%{public}d chars)', cached.length);
      this.scheduleInline(article, cached.substring(READER_MARKER_TEXT.length), article.plainText);
      return cached;
    }

    const running: Promise<string> | undefined = this.inFlight.get(article.id);
    if (running !== undefined) {
      return await running;
    }
    const task: Promise<string> = this.buildReaderHtml(article, fullTextMode, cached, staleSummary);
    this.inFlight.set(article.id, task);
    try {
      return await task;
    } finally {
      this.inFlight.delete(article.id);
    }
  }

  /**
   * 缓存里存的其实就是 feed 那句简介（旧版本的错误行为）。
   * 判据：feed 正文当前判为 SUMMARY，且缓存正文与简介长度接近、开头一致。
   */
  private isFeedSummaryCache(article: Article, cached: string): boolean {
    if (cached.length === 0 || article.contentHtml.length === 0) {
      return false;
    }
    if (feedBodyKind(article.contentHtml) !== FeedBodyKind.SUMMARY) {
      return false;
    }
    const plain: string = toPlainText(readerBodyOf(cached)).trim();
    if (plain.length === 0) {
      return false;
    }
    const summary: string = toPlainText(extractReadable(article.contentHtml, article.link)).trim();
    if (summary.length === 0) {
      return false;
    }
    // 缓存比简介长出很多 → 已经是「简介卡片 + 真实正文」或完整正文，不再算过期。
    const slack: number = Math.max(120, Math.floor(summary.length * 0.3));
    if (plain.length > summary.length + slack) {
      return false;
    }
    const head: string = summary.substring(0, Math.min(60, summary.length));
    const plainHead: string = plain.substring(0, Math.min(40, plain.length));
    return plain.indexOf(head) === 0 || summary.indexOf(plainHead) === 0;
  }

  /** 真正生成正文：取素材 → 提取 → 立即落「文本版」→ 排队补图。 */
  private async buildReaderHtml(article: Article, fullTextMode: string, cached: string,
    staleSummary: boolean = false): Promise<string> {
    article.readerState = ReaderState.LOADING;
    const baseUrl: string = article.link;
    const kind: FeedBodyKind = feedBodyKind(article.contentHtml);
    const allowNetwork: boolean = fullTextMode !== FullTextMode.NEVER;
    // 只有「够长 / 结构够丰富」的 feed 正文才直接当正文用；
    // 一句简介（SUMMARY）即使能联网也要去抓真实页面，否则阅读器里只剩一段话。
    const useFeedBody: boolean = fullTextMode !== FullTextMode.ALWAYS && kind === FeedBodyKind.FULL;
    const summaryHtml: string = kind === FeedBodyKind.SUMMARY
      ? extractReadable(article.contentHtml, baseUrl) : '';

    // 生成一份新的正文片段（按全文策略决定 feed 自带正文 / 联网抓原文）。
    let fresh: string = '';
    let fetchMs: number = 0;
    let extractMs: number = 0;
    try {
      if (useFeedBody) {
        const started: number = Date.now();
        fresh = extractReadable(article.contentHtml, baseUrl);
        extractMs = Date.now() - started;
      } else if (allowNetwork && baseUrl.length > 0) {
        // 走到这里说明没有当前版本缓存（旧版本提取规则可能不同），因此不带条件请求头，
        // 强制拿整页重新提取；否则服务端回 304 时会把旧结果原样复用。
        const fetchStart: number = Date.now();
        const page: PageFetch = await this.fetchPage(baseUrl, '', '');
        fetchMs = Date.now() - fetchStart;
        if (page.etag !== article.pageEtag || page.lastModified !== article.pageLastModified) {
          article.pageEtag = page.etag;
          article.pageLastModified = page.lastModified;
          articleStore.setPageValidators(article.id, page.etag, page.lastModified);
        }
        const started: number = Date.now();
        fresh = extractReadable(page.html, baseUrl);
        extractMs = Date.now() - started;
        // 页面只是 SPA 空壳：正文要等 JS 渲染，静态提取拿不到。给出可区分的失败原因，
        // 上层据此提示「需要 JavaScript」并自动切网页原文。
        if (isSpaShellHtml(page.html) &&
          toPlainText(fresh).trim().length < ReaderConstants.MAX_SPA_SHELL_TEXT_CHARS) {
          throw new ReaderNeedsJsError();
        }
        if (summaryHtml.length > 0) {
          // 抓到真实正文：把 feed 简介作为顶部摘要卡片，而不是丢掉。
          fresh = feedSummaryCard(summaryHtml) + fresh;
        }
      } else {
        // 离线 / 只用 feed 正文：简介就是能拿到的全部内容。
        fresh = summaryHtml;
      }
    } catch (err) {
      if (err instanceof ReaderNeedsJsError) {
        // 旧缓存如果只是那句简介，不值得当作正文返回；否则离线时仍优先保住可读内容。
        if (cached.length > 0 && !staleSummary) {
          article.readerState = ReaderState.READY;
          return cached;
        }
        article.readerState = ReaderState.FAILED;
        throw err;
      }
      // 抓取失败（多为离线）：已有旧缓存就先用着，不打断阅读。
      if (cached.length > 0 && !staleSummary) {
        article.readerState = ReaderState.READY;
        return cached;
      }
      if (summaryHtml.length > 0) {
        const summaryPlain: string = toPlainText(summaryHtml);
        this.persist(article, READER_MARKER_TEXT + summaryHtml, summaryPlain);
        return article.readerHtml;
      }
      if (cached.length > 0) {
        article.readerState = ReaderState.READY;
        return cached;
      }
      article.readerState = ReaderState.FAILED;
      if (err instanceof FeedFetchError) {
        throw err;
      }
      throw new FeedFetchError(FeedError.FETCH_FAILED, 'fetch html failed');
    }

    if (isReaderPlaceholder(fresh, article.link)) {
      hilog.info(DOMAIN, TAG, 'reader placeholder extracted');
      if (cached.length > 0) {
        article.readerState = ReaderState.READY;
        return cached;
      }
      article.readerState = ReaderState.FAILED;
      throw new ReaderPlaceholderError();
    }
    if (fresh.length === 0) {
      if (cached.length > 0) {
        article.readerState = ReaderState.READY;
        return cached;
      }
      article.readerState = ReaderState.FAILED;
      throw new FeedFetchError(FeedError.PARSE_ERROR, 'extract produced empty content');
    }

    // 纯文本用「未内联」的片段算：内联后是多 MB 的 base64，正则扫一遍只会白等。
    const plain: string = toPlainText(fresh);
    // 先落「文本版」并立刻返回 —— 图片（远程链接）由 Web 自己加载，离线补图放后台。
    const persistStart: number = Date.now();
    this.persist(article, READER_MARKER_TEXT + fresh, plain);
    hilog.info(DOMAIN, TAG, 'perf fetch=%{public}dms extract=%{public}dms persist=%{public}dms chars=%{public}d',
      fetchMs, extractMs, Date.now() - persistStart, fresh.length);
    this.scheduleInline(article, fresh, plain);
    return article.readerHtml;
  }

  /**
   * 采用「已渲染 DOM」再提取：SPA 页面只有 JS 跑完才有正文。
   * 由网页原文模式把 `document.documentElement.outerHTML` 传进来，提取成功就落库并返回正文片段；
   * 提取不到返回空串（不改动已有缓存，调用方给失败提示即可）。
   */
  adoptRenderedHtml(article: Article, html: string): string {
    if (html.length === 0) {
      return '';
    }
    const fresh: string = extractReadable(html, article.link);
    if (fresh.length === 0 || isReaderPlaceholder(fresh, article.link)) {
      return '';
    }
    const plain: string = toPlainText(fresh);
    if (plain.trim().length < ReaderConstants.MIN_CONTENT_SCORE) {
      return '';
    }
    this.persist(article, READER_MARKER_TEXT + fresh, plain);
    this.scheduleInline(article, fresh, plain);
    hilog.info(DOMAIN, TAG, 'adopted rendered dom (%{public}d chars)', fresh.length);
    return article.readerHtml;
  }

  /**
   * 排队把正文图片内联为 data URI（离线可读）。
   * 串行执行：预取与当前文章可能同时具备补图条件，并行下载只会互相抢带宽。
   * 延迟 INLINE_DELAY_MS 再开始，让首屏先渲染出来。
   */
  private scheduleInline(article: Article, fresh: string, plain: string): void {
    const token: string = READER_MARKER_TEXT + fresh;
    if (!NetworkStatus.isOnline() || this.inlineScheduled.get(article.id) === token) {
      return;
    }
    this.inlineScheduled.set(article.id, token);
    this.inlineQueue = this.inlineQueue
      .then(() => this.inlineLater(article, fresh, plain, token))
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'inline queue failed: %{public}d', err.code);
      });
  }

  /** 后台补图：只在正文未被替换（重提取 / 切文）时写回。 */
  private async inlineLater(article: Article, fresh: string, plain: string, token: string): Promise<void> {
    try {
      await delay(INLINE_DELAY_MS);
      if (article.readerHtml !== token) {
        return;
      }
      const start: number = Date.now();
      const result: InlineImagesResult = await imageCache.inlineImages(fresh);
      if (article.readerHtml !== token) {
        return;
      }
      // 最后一道总预算：超限则退回未内联的正文，保证单篇体积有界。
      const fitted: string = ReaderBudget.fit(fresh, result.html);
      const budgetRejected: boolean = fitted !== result.html;
      const marker: string = readerImageCacheMarker(result.remainingRemote, result.retryable, budgetRejected);
      const fragment: string = marker + fitted;
      if (fragment === token) {
        // 全部下载失败且仍可重试；保留文本标记，下一次联网打开再补。
        return;
      }
      hilog.info(DOMAIN, TAG, 'perf inline=%{public}dms inlined=%{public}d chars',
        Date.now() - start, fragment.length);
      this.persist(article, fragment, plain);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'inline images failed: %{public}d', error.code);
    } finally {
      if (this.inlineScheduled.get(article.id) === token) {
        this.inlineScheduled.delete(article.id);
      }
    }
  }

  /** 落库：正文片段 + 已算好的纯文本（plain 为空时沿用文章已有的，避免覆盖成空串）。 */
  private persist(article: Article, fragment: string, plain: string): void {
    article.readerHtml = fragment;
    article.readerState = ReaderState.READY;
    const text: string = plain.length > 0 ? plain : article.plainText;
    article.plainText = text;
    try {
      articleStore.setReaderHtml(article.id, fragment, text);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'persist reader html failed: %{public}d', error.code);
    }
  }
}

/** 全局唯一实例。 */
export const articleContentService: ArticleContentService = new ArticleContentService();
