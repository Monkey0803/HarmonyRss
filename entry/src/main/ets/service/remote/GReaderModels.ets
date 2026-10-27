/*
 * GReaderModels.ets — Google Reader API 的协议 DTO 与容错解析（纯函数，便于单测）。
 *
 * 不同实现（FreshRSS / Tiny Tiny RSS / Miniflux）字段略有差异，解析层一律「缺字段给默认值」，
 * 不抛异常；只有整段 JSON 完全无法解析时才由调用方按 PARSE 错误处理。
 */

import { RemoteArticle, RemoteErrorCode, RemoteFeed, RemoteIdPage, RemoteContentsPage } from '../../model/Remote';
import { SearchConstants } from '../../common/constants/RssConstants';
import { toPlainText } from '../../common/utils/HtmlText';

/** 订阅列表响应。 */
interface RawSubscriptionCategory {
  label?: string;
}

interface RawSubscription {
  id?: string;
  title?: string;
  categories?: RawSubscriptionCategory[] | null;
}

interface RawSubscriptionList {
  subscriptions?: RawSubscription[] | null;
}

/** 文章列表响应。 */
interface RawAlternate {
  href?: string;
}

interface RawContentBlock {
  content?: string;
}

interface RawOrigin {
  streamId?: string;
  title?: string;
}

interface RawItem {
  id?: string;
  title?: string;
  published?: number;
  updated?: number;
  alternate?: RawAlternate[] | null;
  summary?: RawContentBlock | null;
  content?: RawContentBlock | null;
  author?: string;
  origin?: RawOrigin | null;
  categories?: string[];
}

interface RawContents {
  items?: RawItem[] | null;
  continuation?: string | number;
}

/** 仅 id 的列表响应。 */
interface RawItemRef {
  id?: string;
}

interface RawIdList {
  itemRefs?: RawItemRef[] | null;
  continuation?: string | number;
}

/** 字符串字段归一（非 string 一律空串）。 */
function textOf(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}

/** 秒 → 毫秒；非法值返回 0。 */
function millisOf(seconds: number | undefined): number {
  if (typeof seconds !== 'number' || seconds <= 0) {
    return 0;
  }
  // 部分实现会直接给毫秒（> 10^11），此时不再乘 1000。
  return seconds > 100000000000 ? Math.round(seconds) : Math.round(seconds * 1000);
}

/** 摘要 / 正文统一裁剪，避免超长 HTML 直接进列表。 */
function plainOf(html: string): string {
  const plain: string = toPlainText(html);
  return plain.length > SearchConstants.SNIPPET_MAX_CHARS * 20
    ? plain.substring(0, SearchConstants.SNIPPET_MAX_CHARS * 20)
    : plain;
}

/** 从 categories 判断某个状态标签是否出现。 */
function hasState(categories: string[] | undefined, suffix: string): boolean {
  if (categories === undefined) {
    return false;
  }
  for (let i = 0; i < categories.length; i += 1) {
    const value: string = textOf(categories[i]);
    if (value.endsWith(suffix)) {
      return true;
    }
  }
  return false;
}

/**
 * 解析 ClientLogin 文本响应，返回 Auth token；没有则空串。
 * 响应形如：`SID=...\nLSID=...\nAuth=xxxx`（也可能只有一行）。
 */
export function parseLoginAuth(body: string): string {
  if (body.length === 0) {
    return '';
  }
  const lines: string[] = body.split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const line: string = lines[i].trim();
    if (line.startsWith('Auth=')) {
      return line.substring(5).trim();
    }
  }
  return '';
}

/** 解析订阅列表（id 形如 `feed/<url>`）。字段缺失 / 非法条目会被跳过。 */
export function parseSubscriptions(body: string): RemoteFeed[] {
  const feeds: RemoteFeed[] = [];
  if (body.length === 0) {
    return feeds;
  }
  let raw: RawSubscriptionList;
  try {
    raw = JSON.parse(body) as RawSubscriptionList;
  } catch (err) {
    return feeds;
  }
  const list: RawSubscription[] | undefined | null = raw.subscriptions;
  if (list === undefined || list === null) {
    return feeds;
  }
  for (let i = 0; i < list.length; i += 1) {
    const item: RawSubscription = list[i];
    const remoteId: string = textOf(item.id);
    if (remoteId.length === 0) {
      continue;
    }
    const url: string = remoteId.startsWith('feed/') ? remoteId.substring(5) : remoteId;
    if (url.length === 0) {
      continue;
    }
    let group: string = '';
    const categories: RawSubscriptionCategory[] | undefined | null = item.categories;
    if (categories !== undefined && categories !== null && categories.length > 0) {
      group = textOf(categories[0].label);
    }
    const title: string = textOf(item.title);
    feeds.push(new RemoteFeed(remoteId, url, title.length > 0 ? title : url, group));
  }
  return feeds;
}

/** 解析文章列表的一页。字段缺失给默认值（标题 / 链接 / 时间 / 作者都可能缺）。 */
export function parseContents(body: string): RemoteContentsPage {
  const items: RemoteArticle[] = [];
  let continuation: string = '';
  if (body.length === 0) {
    return new RemoteContentsPage(items, continuation);
  }
  let raw: RawContents;
  try {
    raw = JSON.parse(body) as RawContents;
  } catch (err) {
    return new RemoteContentsPage(items, continuation);
  }
  if (raw.continuation !== undefined && raw.continuation !== null) {
    continuation = typeof raw.continuation === 'string'
      ? raw.continuation : raw.continuation.toString();
  }
  const list: RawItem[] | undefined | null = raw.items;
  if (list === undefined || list === null) {
    return new RemoteContentsPage(items, continuation);
  }
  for (let i = 0; i < list.length; i += 1) {
    const item: RawItem = list[i];
    const remoteId: string = textOf(item.id);
    if (remoteId.length === 0) {
      continue;
    }
    const origin: RawOrigin | undefined | null = item.origin;
    const feedUrl: string = origin !== undefined && origin !== null ? textOf(origin.streamId) : '';
    const feedTitle: string = origin !== undefined && origin !== null ? textOf(origin.title) : '';
    let link: string = '';
    const alternate: RawAlternate[] | undefined | null = item.alternate;
    if (alternate !== undefined && alternate !== null && alternate.length > 0) {
      link = textOf(alternate[0].href);
    }
    const title: string = textOf(item.title);
    const summaryRaw: string = item.summary !== undefined && item.summary !== null
      ? textOf(item.summary.content) : '';
    const contentRaw: string = item.content !== undefined && item.content !== null
      ? textOf(item.content.content) : '';
    const article: RemoteArticle = new RemoteArticle(
      remoteId, feedUrl, feedTitle,
      title.length > 0 ? title : (link.length > 0 ? link : remoteId),
      link);
    article.summary = plainOf(summaryRaw.length > 0 ? summaryRaw : contentRaw);
    article.content = plainOf(contentRaw.length > 0 ? contentRaw : summaryRaw);
    article.contentHtml = contentRaw.length > 0 ? contentRaw : summaryRaw;
    // published 缺失时用 updated 兜底；两者都缺为 0。
    const published: number = millisOf(item.published);
    article.publishedAt = published > 0 ? published : millisOf(item.updated);
    article.author = textOf(item.author);
    article.read = hasState(item.categories, '/state/com.google/read');
    article.starred = hasState(item.categories, '/state/com.google/starred');
    items.push(article);
  }
  return new RemoteContentsPage(items, continuation);
}

/** 解析 id 列表（未读 / 收藏集合）。 */
export function parseIdPage(body: string): RemoteIdPage {
  const ids: string[] = [];
  let continuation: string = '';
  if (body.length === 0) {
    return new RemoteIdPage(ids, continuation);
  }
  let raw: RawIdList;
  try {
    raw = JSON.parse(body) as RawIdList;
  } catch (err) {
    return new RemoteIdPage(ids, continuation);
  }
  if (raw.continuation !== undefined && raw.continuation !== null) {
    continuation = typeof raw.continuation === 'string'
      ? raw.continuation : raw.continuation.toString();
  }
  const refs: RawItemRef[] | undefined | null = raw.itemRefs;
  if (refs === undefined || refs === null) {
    return new RemoteIdPage(ids, continuation);
  }
  for (let i = 0; i < refs.length; i += 1) {
    const id: string = textOf(refs[i].id);
    if (id.length > 0) {
      ids.push(id);
    }
  }
  return new RemoteIdPage(ids, continuation);
}

/** 写 token 响应就是一行 T（部分实现带空白）。 */
export function parseWriteToken(body: string): string {
  return body.trim();
}

/** HTTP 状态码 → 分类错误。 */
export function errorCodeForStatus(status: number): RemoteErrorCode {
  if (status === 401 || status === 403) {
    return RemoteErrorCode.AUTH;
  }
  if (status === 404) {
    return RemoteErrorCode.API_DISABLED;
  }
  if (status === 429) {
    return RemoteErrorCode.RATE_LIMIT;
  }
  if (status >= 500) {
    return RemoteErrorCode.SERVER;
  }
  if (status >= 400) {
    return RemoteErrorCode.SERVER;
  }
  return RemoteErrorCode.NONE;
}

/**
 * 网络层异常 → 分类错误。
 * @ohos.net.http 的错误码 = 2300000 + curl 错误码；证书类错误按消息关键字识别（不同版本码值不一致）。
 */
export function classifyNetworkFailure(code: number, message: string): RemoteErrorCode {
  const lower: string = message.toLowerCase();
  if (lower.indexOf('certificate') >= 0 || lower.indexOf('ssl') >= 0 || lower.indexOf('tls') >= 0 ||
    code === 2300060 || code === 2300061) {
    return RemoteErrorCode.TLS;
  }
  return RemoteErrorCode.NETWORK;
}

/** 响应正文是否明确表示「API 未开启」（FreshRSS 在部分配置下回 200 + 错误文本）。 */
export function looksLikeApiDisabled(status: number, body: string): boolean {
  if (status === 404) {
    return true;
  }
  const lower: string = body.toLowerCase();
  return lower.indexOf('api is not enabled') >= 0 || lower.indexOf('api not enabled') >= 0 ||
    lower.indexOf('greader') >= 0 && lower.indexOf('not found') >= 0;
}
