/* 网页稍后读：只在用户主动预览时联网，确认后由 ViewModel 写入文章库。 */
import { url } from '@kit.ArkTS';
import { WebPagePreview } from '../model/WebPagePreview';
import { UrlText } from '../common/utils/UrlText';
import { toPlainText } from '../common/utils/HtmlText';
import { decodeEntities } from './RssParser';
import { HtmlNode, parseHtml, textContent } from './HtmlDom';
import { extractReadable } from './Readability';
import { isReaderPlaceholder } from './ReaderContentGuard';
import { articleContentService } from './ArticleContentService';

const PREVIEW_HEAD_CHARS: number = 100000;

/** 只接受普通 http(s) 网页地址，避免把其它协议交给抓取器。 */
export function normalizeWebPageUrl(raw: string): string {
  const normalized: string = UrlText.normalizeUrlInput(raw);
  if (normalized.length === 0 || normalized.length > 4096) {
    return '';
  }
  try {
    const parsed: url.URL = new url.URL(normalized);
    if ((parsed.protocol !== 'https:' && parsed.protocol !== 'http:') || parsed.hostname.length === 0 ||
      parsed.username.length > 0 || parsed.password.length > 0) {
      return '';
    }
    return normalized;
  } catch (err) {
    return '';
  }
}

/** 读网页标题：优先 Open Graph，其次 title；只解析 head 前部，避免遍历整篇正文。 */
export function webPageTitle(html: string): string {
  const root: HtmlNode = parseHtml(html.substring(0, PREVIEW_HEAD_CHARS));
  const stack: HtmlNode[] = [root];
  let documentTitle: string = '';
  while (stack.length > 0) {
    const node: HtmlNode = stack.pop() as HtmlNode;
    if (node.tag === 'meta' && (node.attr('property').toLowerCase() === 'og:title' ||
      node.attr('name').toLowerCase() === 'twitter:title')) {
      const value: string = decodeEntities(node.attr('content')).trim();
      if (value.length > 0) {
        return value.substring(0, 200);
      }
    }
    if (node.tag === 'title' && documentTitle.length === 0) {
      documentTitle = decodeEntities(textContent(node)).trim();
    }
    for (let i = node.children.length - 1; i >= 0; i -= 1) {
      stack.push(node.children[i]);
    }
  }
  return documentTitle.substring(0, 200);
}

/** 解析为可保存的预览；提取不到正文时仍保留链接，详情页可回退网页原文。 */
export function parseWebPagePreview(pageUrl: string, html: string): WebPagePreview {
  const parsed: url.URL = new url.URL(pageUrl);
  const source: string = parsed.hostname;
  const title: string = webPageTitle(html) || source;
  let body: string = extractReadable(html, pageUrl);
  if (isReaderPlaceholder(body, pageUrl)) {
    body = '';
  }
  const plain: string = toPlainText(body);
  const summary: string = plain.substring(0, 160).replace(/\s+/g, ' ').trim();
  const hasRemoteImage: boolean = /<img\b[^>]*\bsrc="https?:/i.test(body);
  const readerHtml: string = body.length > 0
    ? (hasRemoteImage ? '<!--hrv9t-->' : '<!--hrv9-->') + body : '';
  return new WebPagePreview(pageUrl, title, source, summary, plain, readerHtml);
}

export class WebPageSaveService {
  async preview(rawUrl: string): Promise<WebPagePreview | undefined> {
    const pageUrl: string = normalizeWebPageUrl(rawUrl);
    if (pageUrl.length === 0) {
      return undefined;
    }
    const page = await articleContentService.fetchPage(pageUrl, '', '');
    return parseWebPagePreview(pageUrl, page.html);
  }
}

export const webPageSaveService: WebPageSaveService = new WebPageSaveService();
