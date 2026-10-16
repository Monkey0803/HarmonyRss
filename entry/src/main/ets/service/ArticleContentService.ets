/*
 * ArticleContentService.ets — Reader 正文的获取编排（缓存优先 → 抓原文 → 提取 → 落库）。
 *
 * 数据来源优先级：
 *   1. 本地库已有的 reader_html（离线可读，命中即返回）；
 *   2. feed 自带的结构化正文 contentHtml（含块级标签时直接提取，省一次网络请求）；
 *   3. 联网抓 article.link 的 HTML 再提取。
 * 抓取失败 / 提取为空时抛出 FeedFetchError，由上层决定退网页原文。
 */

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { articleStore } from './ArticleStore';
import { extractReadable } from './Readability';
import { imageCache } from './ImageCache';
import { ReaderBudget } from './ReaderBudget';
import { ReaderState, RssConstants, FeedError, FeedFetchError } from '../common/constants/RssConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'ArticleContentService';

/**
 * Reader HTML 版本标记（存在正文片段开头）。
 * 缓存命中要求带标记：旧版本（无标记、未内联图片）会在联网时重新生成一次。
 */
const READER_MARKER: string = '<!--hrv4-->';

/** @ohos.net.http 的错误码 = 2300000 + curl 错误码。 */
const HTTP_ERROR_BASE: number = 2300000;
const CURL_TIMEOUT: number = 28;

function classifyRequestError(error: BusinessError): FeedError {
  return error.code === HTTP_ERROR_BASE + CURL_TIMEOUT ? FeedError.TIMEOUT : FeedError.NETWORK_ERROR;
}

/** contentHtml 是否像「带块级结构」的正文（否则只有纯文本，需联网抓全文）。 */
function looksLikeBodyHtml(html: string): boolean {
  const lower: string = html.toLowerCase();
  return lower.indexOf('<p') >= 0 || lower.indexOf('<div') >= 0 || lower.indexOf('<article') >= 0
    || lower.indexOf('<section') >= 0 || lower.indexOf('<h1') >= 0 || lower.indexOf('<h2') >= 0
    || lower.indexOf('<ul') >= 0 || lower.indexOf('<figure') >= 0 || lower.indexOf('<br') >= 0;
}

export class ArticleContentService {
  /** 抓取一个网页的 HTML 文本（复用订阅抓取的超时 / 错误归类）。 */
  async fetchHtml(url: string): Promise<string> {
    const header: Record<string, string> = {
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      connectTimeout: RssConstants.CONNECT_TIMEOUT_MS,
      readTimeout: RssConstants.READ_TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING,
      header: header
    };
    const request: http.HttpRequest = http.createHttp();
    try {
      let response: http.HttpResponse;
      try {
        response = await request.request(url, options);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        throw new FeedFetchError(classifyRequestError(error), 'network: ' + error.message);
      }
      if (response.responseCode !== http.ResponseCode.OK) {
        throw new FeedFetchError(FeedError.HTTP_ERROR, 'HTTP ' + response.responseCode.toString());
      }
      const raw: string | Object | ArrayBuffer = response.result;
      const body: string = typeof raw === 'string' ? raw : '';
      if (body.length === 0) {
        throw new FeedFetchError(FeedError.EMPTY_RESPONSE, 'empty html body');
      }
      return body;
    } finally {
      request.destroy();
    }
  }

  /**
   * 确保文章拥有 Reader 正文；返回净化后的 HTML 片段（失败抛 FeedFetchError）。
   * 命中当前版本缓存时不发网络请求；旧版本缓存会在联网时重新生成（补上离线图片）。
   * 会同步更新 article.readerHtml / readerState 并落库。
   */
  async ensureReaderHtml(article: Article): Promise<string> {
    const cached: string = article.readerHtml;
    if (cached.length > 0 && cached.startsWith(READER_MARKER)) {
      article.readerState = ReaderState.READY;
      hilog.info(DOMAIN, TAG, 'reader cache hit (%{public}d chars)', cached.length);
      return cached;
    }
    article.readerState = ReaderState.LOADING;
    const baseUrl: string = article.link;

    // 生成一份新的正文片段（feed 自带结构化正文优先，否则抓原文）。
    let fresh: string = '';
    try {
      if (looksLikeBodyHtml(article.contentHtml)) {
        fresh = extractReadable(article.contentHtml, baseUrl);
      } else if (baseUrl.length > 0) {
        const source: string = await this.fetchHtml(baseUrl);
        fresh = extractReadable(source, baseUrl);
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
    try {
      articleStore.setReaderHtml(article.id, fragment);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'persist reader html failed: %{public}d', error.code);
    }
  }
}

/** 全局唯一实例。 */
export const articleContentService: ArticleContentService = new ArticleContentService();
