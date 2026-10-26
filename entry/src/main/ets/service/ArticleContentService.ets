/*
 * ArticleContentService.ets — Reader 正文的获取编排（缓存优先 → 抓原文 → 提取 → 落库）。
 *
 * 数据来源优先级：
 *   1. 本地库已有的 reader_html（离线可读，命中即返回）；
 *   2. feed 自带的结构化正文 contentHtml（含块级标签时直接提取，省一次网络请求）；
 *   3. 联网抓 article.link 的 HTML 再提取。
 * 抓取失败 / 提取为空时抛出 FeedFetchError，由上层决定退网页原文。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { articleStore } from './ArticleStore';
import { toPlainText } from '../common/utils/HtmlText';
import { extractReadable, hasBodyContent } from './Readability';
import { imageCache } from './ImageCache';
import { ReaderBudget } from './ReaderBudget';
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
   * 命中当前版本缓存时不发网络请求；旧版本缓存会在联网时重新生成（补上离线图片）。
   * 会同步更新 article.readerHtml / readerState 并落库。
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
    article.readerState = ReaderState.LOADING;
    const baseUrl: string = article.link;
    const useFeedBody: boolean = fullTextMode !== FullTextMode.ALWAYS && hasBodyContent(article.contentHtml);
    const allowNetwork: boolean = fullTextMode !== FullTextMode.NEVER;

    // 生成一份新的正文片段（按全文策略决定 feed 自带正文 / 联网抓原文）。
    let fresh: string = '';
    try {
      if (useFeedBody) {
        fresh = extractReadable(article.contentHtml, baseUrl);
      } else if (allowNetwork && baseUrl.length > 0) {
        // 走到这里说明没有当前版本缓存（旧版本提取规则可能不同），因此不带条件请求头，
        // 强制拿整页重新提取；否则服务端回 304 时会把旧结果原样复用。
        const page: PageFetch = await this.fetchPage(baseUrl, '', '');
        if (page.etag !== article.pageEtag || page.lastModified !== article.pageLastModified) {
          article.pageEtag = page.etag;
          article.pageLastModified = page.lastModified;
          articleStore.setPageValidators(article.id, page.etag, page.lastModified);
        }
        fresh = extractReadable(page.html, baseUrl);
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

    // 把正文图片内联为 data URI（离线可读）；失败/超预算的图片保留远程链接。
    const inlined: string = await imageCache.inlineImages(fresh, baseUrl);
    // 最后一道总预算：超限则退回未内联的正文，保证单篇体积有界。
    this.persist(article, READER_MARKER + ReaderBudget.fit(fresh, inlined));
    return article.readerHtml;
  }

  private persist(article: Article, fragment: string): void {
    article.readerHtml = fragment;
    article.readerState = ReaderState.READY;
    // 顺带落一份纯文本：搜索要能命中正文，复制 / 分享 / 朗读也在用它。
    const plain: string = toPlainText(fragment);
    article.plainText = plain;
    try {
      articleStore.setReaderHtml(article.id, fragment, plain);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'persist reader html failed: %{public}d', error.code);
    }
  }
}

/** 全局唯一实例。 */
export const articleContentService: ArticleContentService = new ArticleContentService();
