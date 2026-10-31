/*
 * ReaderContentGuard.ets — 识别静态页面里的占位内容，避免把它当成文章正文缓存。
 * 只匹配短且格式明确的提示或站点页脚；正常正文不应触发回退。
 */

import { toPlainText } from '../common/utils/HtmlText';
import { FeedError, FeedFetchError } from '../common/constants/RssConstants';

/** 提取出的内容实际上是网站提示或页脚。 */
export class ReaderPlaceholderError extends FeedFetchError {
  constructor() {
    super(FeedError.PARSE_ERROR, 'reader contains site placeholder');
  }
}

export function isReaderPlaceholder(html: string, articleUrl: string = ''): boolean {
  // 图片内联后的缓存可达数 MB；提示页应很短，避免每次缓存命中都扫描整篇。
  if (html.length === 0 || html.length > 4096) {
    return false;
  }
  const text: string = toPlainText(html).replace(/\s+/g, ' ').trim().toLowerCase();
  if (text.length === 0 || text.length > 300) {
    return false;
  }
  // YouTube watch 页的静态 HTML 可能只提取到站点页脚；视频本身需在网页原文模式显示。
  if (/^https?:\/\/(?:www\.|m\.)?youtube\.com\/watch(?:\?|$)/i.test(articleUrl) &&
    html.includes('youtube.com/about/') && html.includes('youtube.com/t/terms') &&
    text.includes('google llc')) {
    return true;
  }
  const mastodon: string = 'to use the mastodon web application, please enable javascript.';
  if (text === mastodon) {
    return true;
  }
  if (text === mastodon + ' alternatively, try one of the native apps for mastodon for your platform.') {
    return true;
  }
  return text === 'you need to enable javascript to run this app.';
}
