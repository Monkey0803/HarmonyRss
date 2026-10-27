/*
 * FeedbinModels.ets — Feedbin REST API 的 DTO 与容错解析（纯函数，便于单测）。
 *
 * 只负责 JSON → 领域模型；认证、分页与状态回写在 FeedbinBackend。
 * 字段缺失 / 类型不符一律降级为空值，不抛异常（只有整段 JSON 无法解析时返回空页）。
 */

import { url } from '@kit.ArkTS';
import { RemoteArticle, RemoteFeed } from '../../model/Remote';
import { SearchConstants } from '../../common/constants/RssConstants';
import { toPlainText } from '../../common/utils/HtmlText';
import { RemoteArticlePage } from './RemoteBackend';

/** Feedbin 默认 API 根地址（不含 /v2）。 */
export const FEEDBIN_DEFAULT_BASE: string = 'https://api.feedbin.com';

interface FeedbinSubscriptionRaw {
  id?: number;
  feed_id?: number;
  title?: string;
  feed_url?: string;
  site_url?: string;
}

interface FeedbinEntryRaw {
  id?: number;
  feed_id?: number;
  title?: string;
  url?: string;
  author?: string;
  content?: string;
  summary?: string;
  published?: string;
  created_at?: string;
}

function textOf(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}

function idText(value: number | undefined): string {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
    ? Math.round(value).toString()
    : '';
}

/** ISO 8601 → 毫秒；非法返回 0。 */
export function isoMillis(value: string): number {
  if (value.length === 0) {
    return 0;
  }
  const parsed: number = Date.parse(value);
  return Number.isNaN(parsed) ? 0 : parsed;
}

/** 两个 ISO 游标取较晚者（时间戳解析失败时退回字符串比较）。 */
export function betterIsoCursor(current: string, candidate: string): string {
  if (candidate.length === 0) {
    return current;
  }
  if (current.length === 0) {
    return candidate;
  }
  const currentMs: number = isoMillis(current);
  const candidateMs: number = isoMillis(candidate);
  if (currentMs > 0 && candidateMs > 0) {
    return candidateMs > currentMs ? candidate : current;
  }
  return candidate > current ? candidate : current;
}

/** Feedbin API 根地址归一：空值用默认地址；补 https、去末尾 `/v2` 与斜杠。 */
export function normalizeFeedbinBaseUrl(input: string): string {
  let value: string = input.trim();
  if (value.length === 0) {
    return FEEDBIN_DEFAULT_BASE;
  }
  if (value.indexOf('://') < 0) {
    value = 'https://' + value;
  }
  try {
    const parsed: url.URL = new url.URL(value);
    const host: string = parsed.hostname;
    if (host.length === 0) {
      return '';
    }
    let path: string = parsed.pathname;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path === '/') {
      path = '';
    }
    if (path.endsWith('/v2')) {
      path = path.substring(0, path.length - 3);
    }
    return parsed.protocol + '//' + host + path;
  } catch (err) {
    return '';
  }
}

/** 拼接 `/v2` 开头的 API 路径。 */
export function feedbinApiUrl(baseUrl: string, path: string): string {
  return normalizeFeedbinBaseUrl(baseUrl) + '/v2' + path;
}

/** 订阅列表。 */
export function parseFeedbinSubscriptions(body: string): RemoteFeed[] {
  const feeds: RemoteFeed[] = [];
  if (body.length === 0) {
    return feeds;
  }
  let raw: FeedbinSubscriptionRaw[];
  try {
    raw = JSON.parse(body);
  } catch (err) {
    return feeds;
  }
  if (!Array.isArray(raw)) {
    return feeds;
  }
  const seen: Set<string> = new Set();
  for (let i = 0; i < raw.length; i += 1) {
    const item: FeedbinSubscriptionRaw = raw[i];
    const feedId: string = idText(item.feed_id);
    const feedUrl: string = textOf(item.feed_url);
    if (feedId.length === 0 || feedUrl.length === 0 || seen.has(feedUrl)) {
      continue;
    }
    seen.add(feedUrl);
    const title: string = textOf(item.title);
    feeds.push(new RemoteFeed(feedId, feedUrl, title.length > 0 ? title : feedUrl, ''));
  }
  return feeds;
}

/** 一页文章；cursor 为该页与传入游标中的较晚 `created_at`。 */
export function parseFeedbinEntries(body: string, feed: RemoteFeed, currentCursor: string): RemoteArticlePage {
  const items: RemoteArticle[] = [];
  let cursor: string = currentCursor;
  if (body.length === 0) {
    return new RemoteArticlePage(items, '', cursor);
  }
  let raw: FeedbinEntryRaw[];
  try {
    raw = JSON.parse(body);
  } catch (err) {
    return new RemoteArticlePage(items, '', cursor);
  }
  if (!Array.isArray(raw)) {
    return new RemoteArticlePage(items, '', cursor);
  }
  for (let i = 0; i < raw.length; i += 1) {
    const item: FeedbinEntryRaw = raw[i];
    const remoteId: string = idText(item.id);
    if (remoteId.length === 0) {
      continue;
    }
    const link: string = textOf(item.url);
    const titleRaw: string = textOf(item.title);
    const title: string = titleRaw.length > 0 ? titleRaw : (link.length > 0 ? link : remoteId);
    const contentHtml: string = textOf(item.content);
    const summaryHtml: string = textOf(item.summary);
    const article: RemoteArticle = new RemoteArticle(remoteId, feed.url, feed.title, title, link);
    article.contentHtml = contentHtml;
    article.content = plainOf(contentHtml.length > 0 ? contentHtml : summaryHtml);
    article.summary = plainOf(summaryHtml.length > 0 ? summaryHtml : contentHtml);
    article.author = textOf(item.author);
    const published: number = isoMillis(textOf(item.published));
    const createdAt: number = isoMillis(textOf(item.created_at));
    article.publishedAt = published > 0 ? published : createdAt;
    article.read = false;
    article.starred = false;
    items.push(article);

    const createdAtText: string = textOf(item.created_at);
    const cursorCandidate: string = createdAtText.length > 0
      ? createdAtText
      : textOf(item.published);
    cursor = betterIsoCursor(cursor, cursorCandidate);
  }
  return new RemoteArticlePage(items, '', cursor);
}

/** id 数组（未读 / 收藏 / 回写响应）。 */
export function parseFeedbinIds(body: string): string[] {
  const result: string[] = [];
  if (body.length === 0) {
    return result;
  }
  let raw: number[];
  try {
    raw = JSON.parse(body);
  } catch (err) {
    return result;
  }
  if (!Array.isArray(raw)) {
    return result;
  }
  for (let i = 0; i < raw.length; i += 1) {
    const text: string = idText(raw[i]);
    if (text.length > 0) {
      result.push(text);
    }
  }
  return result;
}

interface FeedbinFeedOptionRaw {
  feed_url?: string;
}

/** 300 Multiple Choices 响应里的候选 feed_url。 */
export function parseFeedbinFeedOptions(body: string): string[] {
  const result: string[] = [];
  if (body.length === 0) {
    return result;
  }
  let raw: FeedbinFeedOptionRaw[];
  try {
    raw = JSON.parse(body);
  } catch (err) {
    return result;
  }
  if (!Array.isArray(raw)) {
    return result;
  }
  for (let i = 0; i < raw.length; i += 1) {
    const value: string = textOf(raw[i].feed_url);
    if (value.length > 0) {
      result.push(value);
    }
  }
  return result;
}

/** 摘要 / 正文裁剪（与 GReader 解析保持同一上限）。 */
function plainOf(html: string): string {
  if (html.length === 0) {
    return '';
  }
  const plain: string = toPlainText(html);
  const limit: number = SearchConstants.SNIPPET_MAX_CHARS * 20;
  return plain.length > limit ? plain.substring(0, limit) : plain;
}
