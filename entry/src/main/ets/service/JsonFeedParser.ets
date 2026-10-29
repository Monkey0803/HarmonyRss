/*
 * JsonFeedParser.ets — JSON Feed 1.x 解析（纯函数，无副作用）。
 *
 * JSON Feed 是社区标准（application/feed+json），结构比 XML 简单；这里沿用 ParsedFeed /
 * ParsedArticle，让上层完全不用区分来源格式。
 * JSON.parse 的返回值先按「原始结构」整体断言一次，再逐字段做 typeof 校验后拷进严格模型。
 */

import { ParsedArticle, ParsedFeed, stripTags } from './RssParser';
import { summarizeForList } from '../common/utils/SummaryText';
import { RssConstants } from '../common/constants/RssConstants';
import { Enclosure } from '../model/Enclosure';

/** JSON Feed 原始结构（宽松，全部可选）。 */
interface JsonFeedAuthorRaw {
  name?: string;
}

interface JsonFeedAttachmentRaw {
  url?: string;
  mime_type?: string;
  size_in_bytes?: number;
  duration_in_seconds?: number;
}

interface JsonFeedItemRaw {
  id?: string;
  url?: string;
  external_url?: string;
  title?: string;
  content_html?: string;
  content_text?: string;
  summary?: string;
  date_published?: string;
  image?: string;
  author?: JsonFeedAuthorRaw;
  attachments?: JsonFeedAttachmentRaw[];
}

interface JsonFeedRaw {
  title?: string;
  home_page_url?: string;
  items?: JsonFeedItemRaw[];
}

function asString(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}

function parseDate(value: string): number {
  const text: string = value.trim();
  if (text.length === 0) {
    return 0;
  }
  const parsed: number = Date.parse(text);
  return Number.isNaN(parsed) ? 0 : parsed;
}

/** JSON Feed attachments → 媒体附件。 */
function toEnclosures(item: JsonFeedItemRaw): Enclosure[] {
  const result: Enclosure[] = [];
  const attachments: JsonFeedAttachmentRaw[] | undefined = item.attachments;
  if (attachments === undefined) {
    return result;
  }
  for (let i = 0; i < attachments.length; i += 1) {
    const raw: JsonFeedAttachmentRaw = attachments[i];
    const url: string = asString(raw.url);
    if (url.length === 0) {
      continue;
    }
    const type: string = asString(raw.mime_type);
    const length: number = typeof raw.size_in_bytes === 'number' && raw.size_in_bytes > 0
      ? raw.size_in_bytes : 0;
    const duration: number = typeof raw.duration_in_seconds === 'number' && raw.duration_in_seconds > 0
      ? raw.duration_in_seconds : 0;
    result.push(new Enclosure(url, type, length, duration));
  }
  return result;
}

function toArticle(item: JsonFeedItemRaw): ParsedArticle {
  let link: string = asString(item.url);
  if (link.length === 0) {
    link = asString(item.external_url);
  }
  const html: string = asString(item.content_html);
  const plain: string = asString(item.content_text);
  const bodySource: string = html.length > 0 ? html : plain;
  const content: string = plain.length > 0 ? plain : stripTags(html);
  let summarySource: string = asString(item.summary);
  if (summarySource.length === 0) {
    summarySource = bodySource;
  }
  const author: string = item.author === undefined ? '' : asString(item.author.name);
  const title: string = asString(item.title);
  return new ParsedArticle(title, link,
    summarizeForList(stripTags(summarySource), title, RssConstants.SUMMARY_MAX_CHARS), content,
    parseDate(asString(item.date_published)), asString(item.image), author, html, toEnclosures(item));
}

/** 解析 JSON Feed 文档。 */
export function parseJsonFeed(json: string): ParsedFeed {
  const raw: JsonFeedRaw = JSON.parse(json) as JsonFeedRaw;
  const articles: ParsedArticle[] = [];
  const items: JsonFeedItemRaw[] | undefined = raw.items;
  if (items !== undefined) {
    const limit: number = items.length < RssConstants.MAX_ARTICLES_PER_FEED
      ? items.length
      : RssConstants.MAX_ARTICLES_PER_FEED;
    for (let i = 0; i < limit; i += 1) {
      articles.push(toArticle(items[i]));
    }
  }
  return new ParsedFeed(asString(raw.title), asString(raw.home_page_url), articles);
}
