/*
 * ArticleContentService.ets — Reader 正文的获取编排（缓存优先 → 抓原文 → 提取 → 落库）。
 *
 * 数据来源优先级：
 *   1. 本地库已有的 reader_html（离线可读，命中即返回）；
 *   2. feed 自带的结构化正文 contentHtml（含块级标签时直接提取，省一次网络请求）；
 *   3. 联网抓 article.link 的 HTML 再提取。
 * 抓取失败 / 提取为空时抛出 FeedFetchError，由上层决定退网页原文。
 *
 * 两级缓存标记（图片内联是「为了离线可读」，不该挡在首屏前面）：
 *   <!--hrv5t--> 文本已就绪、图片仍是远程链接 —— 立即返回，联网时后台串行补图；
 *   <!--hrv5-->  文本 + 图片都已就绪 —— 真正的完整离线缓存。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { articleStore } from './ArticleStore';
import { toPlainText } from '../common/utils/HtmlText';
import { extractReadable, hasBodyContent } from './Readability';
import { imageCache } from './ImageCache';
import { ReaderBudget } from './ReaderBudget';
import { NetworkStatus } from './NetworkStatus';
import { ReaderState, RssConstants, FeedError, FeedFetchError } from '../common/constants/RssConstants';
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
 * 缓存命中要求带标记：旧版本（无标记、未内联图片）会在联网时重新生成一次。
 */
const READER_MARKER: string = '<!--hrv5-->';
/**
 * 「文本就绪」标记：正文可立即展示，图片仍是远程链接。
 * 联网时后台串行补图，成功后再升级为 READER_MARKER。
 */
const READER_MARKER_TEXT: string = '<!--hrv5t-->';
/** 首屏渲染完成后再开始补图（避免与 Web 首次加载抢带宽与主线程）。 */
const INLINE_DELAY_MS: number = 2000;

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
  /** 已排队的补图任务（同一篇不重复排）。 */
  private inlineScheduled: Set<string> = new Set<string>();

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
    const cached: string = article.readerHtml;
    if (cached.length > 0 && cached.startsWith(READER_MARKER)) {
      article.readerState = ReaderState.READY;
      hilog.info(DOMAIN, TAG, 'reader cache hit (%{public}d chars)', cached.length);
      return cached;
    }
    if (cached.length > 0 && cached.startsWith(READER_MARKER_TEXT)) {
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
    const task: Promise<string> = this.buildReaderHtml(article, fullTextMode, cached);
    this.inFlight.set(article.id, task);
    try {
      return await task;
    } finally {
      this.inFlight.delete(article.id);
    }
  }

  /** 真正生成正文：取素材 → 提取 → 立即落「文本版」→ 排队补图。 */
  private async buildReaderHtml(article: Article, fullTextMode: string, cached: string): Promise<string> {
    article.readerState = ReaderState.LOADING;
    const baseUrl: string = article.link;
    const useFeedBody: boolean = fullTextMode !== FullTextMode.ALWAYS && hasBodyContent(article.contentHtml);
    const allowNetwork: boolean = fullTextMode !== FullTextMode.NEVER;

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
      }
    } catch (err) {
      // 抓取失败（多为离线）：已有旧缓存就先用着，不打断阅读。
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
   * 排队把正文图片内联为 data URI（离线可读）。
   * 串行执行：预取与当前文章可能同时具备补图条件，并行下载只会互相抢带宽。
   * 延迟 INLINE_DELAY_MS 再开始，让首屏先渲染出来。
   */
  private scheduleInline(article: Article, fresh: string, plain: string): void {
    const token: string = READER_MARKER_TEXT + fresh;
    // 以 token 去重（而不是文章 id）：重新提取会产出新 token，旧任务自然失效。
    if (!NetworkStatus.isOnline() || this.inlineScheduled.has(token)) {
      return;
    }
    this.inlineScheduled.add(token);
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
      const inlined: string = await imageCache.inlineImages(fresh, article.link);
      if (inlined === fresh) {
        // 一张都没内联成功（离线 / 全超预算）：保留文本标记，下次打开再试。
        return;
      }
      if (article.readerHtml !== token) {
        return;
      }
      // 最后一道总预算：超限则退回未内联的正文，保证单篇体积有界。
      const fragment: string = READER_MARKER + ReaderBudget.fit(fresh, inlined);
      hilog.info(DOMAIN, TAG, 'perf inline=%{public}dms inlined=%{public}d chars',
        Date.now() - start, fragment.length);
      this.persist(article, fragment, plain);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'inline images failed: %{public}d', error.code);
    } finally {
      this.inlineScheduled.delete(token);
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
