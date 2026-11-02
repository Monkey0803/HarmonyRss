/*
 * ReaderContentGuard.ets — 识别静态页面里的占位内容，避免把它当成文章正文缓存。
 * 只匹配短且格式明确的提示或站点页脚；正常正文不应触发回退。
 */

import { toPlainText } from '../common/utils/HtmlText';
import { FeedError, FeedFetchError, ReaderConstants } from '../common/constants/RssConstants';

/** 提取出的内容实际上是网站提示或页脚。 */
export class ReaderPlaceholderError extends FeedFetchError {
  constructor() {
    super(FeedError.PARSE_ERROR, 'reader contains site placeholder');
  }
}

/**
 * 页面只有 SPA 空壳（<div id="root"></div> + 打包脚本），正文要等 JS 渲染。
 * 与 ReaderPlaceholderError 区分开：文案要说「需要 JavaScript」而不是「提取失败」。
 */
export class ReaderNeedsJsError extends FeedFetchError {
  constructor() {
    super(FeedError.PARSE_ERROR, 'reader requires javascript rendering');
  }
}

/** 常见前端框架的挂载容器 id。 */
const MOUNT_ID_PATTERN: RegExp = /id=["'](root|app|__next|__nuxt|application|main-app)["']/i;
/** 外链脚本：SPA 的入口 bundle。 */
const SCRIPT_SRC_PATTERN: RegExp = /<script\b[^>]*\bsrc=/i;

/**
 * 静态 HTML 是否只是「客户端渲染空壳」（纯函数，可单测）。
 *
 * 判据：有框架挂载容器 + 外链脚本 + 可见文本很少。
 * 典型：React 的 `<div id="root"></div>`，构建产物在 `/assets/index-*.js`，
 * 页面本身不写 noscript 提示，所以静态提取只能拿到空内容。
 */
export function isSpaShellHtml(html: string): boolean {
  if (html.length === 0 || html.length > ReaderConstants.MAX_SPA_SHELL_HTML_CHARS) {
    return false;
  }
  if (!MOUNT_ID_PATTERN.test(html) || !SCRIPT_SRC_PATTERN.test(html)) {
    return false;
  }
  const text: string = toPlainText(html).replace(/\s+/g, ' ').trim();
  return text.length < ReaderConstants.MAX_SPA_SHELL_TEXT_CHARS;
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
