/*
 * JsonFeedParser.ets — JSON Feed 1.x 解析（纯函数，无副作用）。
 *
 * JSON Feed 是社区标准（application/feed+json），结构比 XML 简单；这里沿用 ParsedFeed /
 * ParsedArticle，让上层完全不用区分来源格式。
 * JSON.parse 的返回值先按「原始结构」整体断言一次，再逐字段做 typeof 校验后拷进严格模型。
 */

import { ParsedArticle, ParsedFeed, stripTags } from './RssParser';
import { RssConstants } from '../common/constants/RssConstants';

/** JSON Feed 原始结构（宽松，全部可选）。 */
interface JsonFeedAuthorRaw {
  name?: string;
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

function summarize(source: string): string {
  const text: string = stripTags(source);
  if (text.length <= RssConstants.SUMMARY_MAX_CHARS) {
    return text;
  }
  return text.substring(0, RssConstants.SUMMARY_MAX_CHARS) + '...';
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
  return new ParsedArticle(asString(item.title), link, summarize(summarySource), content,
    parseDate(asString(item.date_published)), asString(item.image), author);
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
