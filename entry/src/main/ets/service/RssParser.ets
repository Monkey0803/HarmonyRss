/*
 * RssParser.ets — RSS 2.0 / Atom 1.0 的纯文本解析（无副作用，便于单测）。
 *
 * 不依赖 DOM / XmlPullParser：feed 文档结构简单且高度约定化，用定长 token 扫描足够稳健，
 * 也避免了 ArkTS 里层层 any 的类型问题。所有辅助函数都放在文件作用域（ArkTS 不允许嵌套函数声明）。
 */

import { RssConstants } from '../common/constants/RssConstants';
import { Enclosure } from '../model/Enclosure';
import { durationFromText, numberFromText } from './EnclosureCodec';

/** 解析出的条目。 */
export class ParsedArticle {
  readonly title: string;
  readonly link: string;
  readonly summary: string;
  readonly content: string;
  readonly publishedAt: number;
  /** 配图地址（media:content / enclosure / 正文首图），没有则为空串。 */
  readonly imageUrl: string;
  /** 作者（dc:creator / author / Atom author/name），没有则为空串。 */
  readonly author: string;
  /** feed 自带的 HTML 正文（保留块级结构，仅去 script/style），没有则为空串。 */
  readonly contentHtml: string;
  /** 媒体附件（播客 / 视频）；没有则为空数组。 */
  readonly enclosures: Enclosure[];

  constructor(title: string, link: string, summary: string, content: string, publishedAt: number,
    imageUrl: string, author: string = '', contentHtml: string = '',
    enclosures: Enclosure[] = []) {
    this.title = title;
    this.link = link;
    this.summary = summary;
    this.content = content;
    this.publishedAt = publishedAt;
    this.imageUrl = imageUrl;
    this.author = author;
    this.contentHtml = contentHtml;
    this.enclosures = enclosures;
  }
}

/** 解析结果。 */
export class ParsedFeed {
  readonly title: string;
  readonly siteUrl: string;
  readonly articles: ParsedArticle[];

  constructor(title: string, siteUrl: string, articles: ParsedArticle[]) {
    this.title = title;
    this.siteUrl = siteUrl;
    this.articles = articles;
  }
}

function replaceAllLiteral(source: string, search: string, value: string): string {
  return source.split(search).join(value);
}

/** 解码十进制 / 十六进制数字实体（&#39; / &#x27;）。 */
function replaceNumericEntities(source: string): string {
  let out: string = '';
  let index: number = 0;
  while (index < source.length) {
    const start: number = source.indexOf('&#', index);
    if (start < 0) {
      out += source.substring(index);
      break;
    }
    out += source.substring(index, start);
    const semi: number = source.indexOf(';', start);
    if (semi < 0) {
      out += source.substring(start);
      break;
    }
    const body: string = source.substring(start + 2, semi);
    let code: number = -1;
    if (body.length > 0 && (body.charAt(0) === 'x' || body.charAt(0) === 'X')) {
      code = Number.parseInt(body.substring(1), 16);
    } else {
      code = Number.parseInt(body, 10);
    }
    if (Number.isNaN(code) || code < 0) {
      out += source.substring(start, semi + 1);
    } else {
      out += String.fromCharCode(code);
    }
    index = semi + 1;
  }
  return out;
}

/** 解码常见 XML 实体；&amp; 放在最后，避免二次解码。 */
export function decodeEntities(input: string): string {
  let out: string = input;
  out = replaceAllLiteral(out, '&lt;', '<');
  out = replaceAllLiteral(out, '&gt;', '>');
  out = replaceAllLiteral(out, '&quot;', '"');
  out = replaceAllLiteral(out, '&apos;', "'");
  out = replaceAllLiteral(out, '&nbsp;', ' ');
  out = replaceNumericEntities(out);
  out = replaceAllLiteral(out, '&amp;', '&');
  return out;
}

/** 去掉 HTML 标签并压缩空白，得到可读纯文本。 */
export function stripTags(input: string): string {
  let out: string = input.replace(new RegExp('<[^>]*>', 'g'), ' ');
  out = out.replace(new RegExp('\\s+', 'g'), ' ');
  return out.trim();
}

/** feed 全文的基础清理：去注释 / script / style，保留块级结构（供 Reader 提取复用）。 */
function basicCleanHtml(input: string): string {
  let out: string = input;
  out = out.replace(new RegExp('<!--[\\s\\S]*?-->', 'g'), '');
  out = out.replace(new RegExp('<script[\\s\\S]*?</script>', 'gi'), '');
  out = out.replace(new RegExp('<style[\\s\\S]*?</style>', 'gi'), '');
  return out.trim();
}

function truncate(text: string, max: number): string {
  if (text.length <= max) {
    return text;
  }
  return text.substring(0, max) + '...';
}

/** 去掉 <![CDATA[ ]]> 包裹并 trim。 */
function cleanValue(raw: string): string {
  let value: string = raw.trim();
  const cdataStart: string = '<![CDATA[';
  if (value.startsWith(cdataStart)) {
    value = value.substring(cdataStart.length);
    const cdataEnd: number = value.indexOf(']]>');
    if (cdataEnd >= 0) {
      value = value.substring(0, cdataEnd);
    }
  }
  return value.trim();
}

/**
 * 读取某个标签的文本内容（首个匹配）。
 *
 * 找结束标签时会统计同名开标签的嵌套层数（depth），保证 `<title>a<title>b</title></title>`
 * 这类畸形/嵌套结构也能取到正确的一段，而不是在第一个 `</title>` 就截断。
 */
function readTagText(xml: string, tag: string): string {
  const openToken: string = '<' + tag;
  const closeToken: string = '</' + tag + '>';
  const start: number = xml.indexOf(openToken);
  if (start < 0) {
    return '';
  }
  const openEnd: number = xml.indexOf('>', start);
  if (openEnd < 0) {
    return '';
  }
  // 自闭合（如 <link ... />）没有文本内容
  if (openEnd > 0 && xml.charAt(openEnd - 1) === '/') {
    return '';
  }
  let depth: number = 1;
  let cursor: number = openEnd + 1;
  while (cursor < xml.length) {
    const nextOpen: number = xml.indexOf(openToken, cursor);
    const nextClose: number = xml.indexOf(closeToken, cursor);
    if (nextClose < 0) {
      return '';
    }
    if (nextOpen >= 0 && nextOpen < nextClose) {
      const nextOpenEnd: number = xml.indexOf('>', nextOpen);
      if (nextOpenEnd > 0 && xml.charAt(nextOpenEnd - 1) !== '/') {
        depth += 1;
      }
      cursor = nextOpenEnd >= 0 ? nextOpenEnd + 1 : nextClose;
      continue;
    }
    depth -= 1;
    if (depth === 0) {
      return cleanValue(xml.substring(openEnd + 1, nextClose));
    }
    cursor = nextClose + closeToken.length;
  }
  return '';
}

/**
 * 解析 Atom 的 link：优先 rel="alternate"（正文地址），其次没有 rel 的，
 * 最后才退回第一个带 href 的 —— 很多 feed 的第一个 link 是 rel="self"（feed 自身地址）。
 */
function readAtomLink(xml: string): string {
  let fallback: string = '';
  let searchFrom: number = 0;
  while (searchFrom < xml.length) {
    const start: number = xml.indexOf('<link', searchFrom);
    if (start < 0) {
      break;
    }
    const openEnd: number = xml.indexOf('>', start);
    if (openEnd < 0) {
      break;
    }
    const header: string = xml.substring(start, openEnd + 1);
    const href: string = attrOf(header, 'href');
    const rel: string = attrOf(header, 'rel');
    if (href.length > 0) {
      if (rel === 'alternate') {
        return href;
      }
      if (rel.length === 0 && fallback.length === 0) {
        fallback = href;
      } else if (fallback.length === 0) {
        fallback = href;
      }
    }
    searchFrom = openEnd + 1;
  }
  return fallback;
}

/** 从单个标签文本里取属性值（找不到返回空串）。 */
function attrOf(tagText: string, attr: string): string {
  const attrToken: string = attr + '=';
  const attrIndex: number = tagText.indexOf(attrToken);
  if (attrIndex < 0) {
    return '';
  }
  let rest: string = tagText.substring(attrIndex + attrToken.length).trim();
  const quote: string = rest.charAt(0);
  if (quote !== '"' && quote !== '\'') {
    return '';
  }
  rest = rest.substring(1);
  const endQuote: number = rest.indexOf(quote);
  return endQuote < 0 ? '' : rest.substring(0, endQuote);
}

/** 读取某个标签的属性值（首个匹配），如 <link href="..."/>。 */
function readTagAttr(xml: string, tag: string, attr: string): string {
  const openToken: string = '<' + tag;
  const start: number = xml.indexOf(openToken);
  if (start < 0) {
    return '';
  }
  const openEnd: number = xml.indexOf('>', start);
  if (openEnd < 0) {
    return '';
  }
  const header: string = xml.substring(start, openEnd + 1);
  const attrToken: string = attr + '=';
  const attrIndex: number = header.indexOf(attrToken);
  if (attrIndex < 0) {
    return '';
  }
  let rest: string = header.substring(attrIndex + attrToken.length).trim();
  const quote: string = rest.charAt(0);
  if (quote !== '"' && quote !== "'") {
    return '';
  }
  rest = rest.substring(1);
  const endQuote: number = rest.indexOf(quote);
  if (endQuote < 0) {
    return '';
  }
  return rest.substring(0, endQuote);
}

/** 切出所有开标签文本（`<tag ...>`，含自闭合），用于 enclosure / link / media:content。 */
function findOpenTags(xml: string, tag: string): string[] {
  const tags: string[] = [];
  const openToken: string = '<' + tag;
  let searchFrom: number = 0;
  while (searchFrom < xml.length) {
    const start: number = xml.indexOf(openToken, searchFrom);
    if (start < 0) {
      break;
    }
    const openEnd: number = xml.indexOf('>', start);
    if (openEnd < 0) {
      break;
    }
    const nextChar: string = xml.charAt(start + openToken.length);
    // 避免 <link> 命中 <linkage> 之类：要求标签名后是空白 / '>' / '/'。
    if (nextChar === '' || nextChar === '>' || nextChar === '/' || nextChar === ' ' ||
      nextChar === '\n' || nextChar === '\r' || nextChar === '\t') {
      tags.push(xml.substring(start, openEnd + 1));
    }
    searchFrom = openEnd + 1;
  }
  return tags;
}

/** 切出所有 <tag>...</tag> 块（支持带属性的开标签）。 */
function findBlocks(xml: string, tag: string): string[] {
  const blocks: string[] = [];
  const openToken: string = '<' + tag;
  const closeToken: string = '</' + tag + '>';
  let searchFrom: number = 0;
  while (searchFrom < xml.length) {
    const start: number = xml.indexOf(openToken, searchFrom);
    if (start < 0) {
      break;
    }
    const openEnd: number = xml.indexOf('>', start);
    if (openEnd < 0) {
      break;
    }
    const end: number = xml.indexOf(closeToken, openEnd);
    if (end < 0) {
      break;
    }
    blocks.push(xml.substring(openEnd + 1, end));
    searchFrom = end + closeToken.length;
  }
  return blocks;
}

/** 解析 RFC822 / ISO8601 时间；解析不到返回 0。 */
function parseDate(value: string): number {
  const text: string = value.trim();
  if (text.length === 0) {
    return 0;
  }
  const direct: number = Date.parse(text);
  if (!Number.isNaN(direct)) {
    return direct;
  }
  const iso: number = Date.parse(text.replace(' ', 'T'));
  if (!Number.isNaN(iso)) {
    return iso;
  }
  return 0;
}

/** 追加附件（同 URL 只保留第一条）。 */
function appendEnclosure(list: Enclosure[], url: string, type: string, length: number, duration: number): void {
  const trimmed: string = url.trim();
  if (trimmed.length === 0) {
    return;
  }
  for (let i = 0; i < list.length; i += 1) {
    if (list[i].url === trimmed) {
      return;
    }
  }
  list.push(new Enclosure(trimmed, type.trim(), length, duration));
}

/**
 * 解析媒体附件：
 *   - RSS <enclosure url type length>；
 *   - Atom <link rel="enclosure" href type length>；
 *   - Media RSS <media:content url type|medium duration>；
 *   - <itunes:duration> 作为时长兜底。
 */
function parseEnclosures(block: string, isAtom: boolean): Enclosure[] {
  const list: Enclosure[] = [];
  const itunesDuration: number = durationFromText(readTagText(block, 'itunes:duration'));

  const enclosures: string[] = findOpenTags(block, 'enclosure');
  for (let i = 0; i < enclosures.length; i += 1) {
    const tag: string = enclosures[i];
    appendEnclosure(list, attrOf(tag, 'url'), attrOf(tag, 'type'),
      numberFromText(attrOf(tag, 'length')), itunesDuration);
  }

  if (isAtom) {
    const links: string[] = findOpenTags(block, 'link');
    for (let i = 0; i < links.length; i += 1) {
      const tag: string = links[i];
      if (attrOf(tag, 'rel') !== 'enclosure') {
        continue;
      }
      appendEnclosure(list, attrOf(tag, 'href'), attrOf(tag, 'type'),
        numberFromText(attrOf(tag, 'length')), itunesDuration);
    }
  }

  const mediaContents: string[] = findOpenTags(block, 'media:content');
  for (let i = 0; i < mediaContents.length; i += 1) {
    const tag: string = mediaContents[i];
    const type: string = attrOf(tag, 'type');
    const medium: string = attrOf(tag, 'medium');
    const mediaDuration: number = numberFromText(attrOf(tag, 'duration'));
    appendEnclosure(list, attrOf(tag, 'url'), type.length > 0 ? type : medium,
      numberFromText(attrOf(tag, 'fileSize')), mediaDuration > 0 ? mediaDuration : itunesDuration);
  }
  return list;
}

/** 配图：media:content → enclosure（图片类型）→ 正文里第一个 <img src>。 */
function firstImageUrl(block: string, rawBody: string): string {
  const mediaUrl: string = readTagAttr(block, 'media:content', 'url');
  if (mediaUrl.length > 0) {
    return mediaUrl;
  }
  const enclosureType: string = readTagAttr(block, 'enclosure', 'type');
  if (enclosureType.length === 0 || enclosureType.startsWith('image')) {
    const enclosureUrl: string = readTagAttr(block, 'enclosure', 'url');
    if (enclosureUrl.length > 0) {
      return enclosureUrl;
    }
  }
  const imgIndex: number = rawBody.indexOf('<img');
  if (imgIndex < 0) {
    return '';
  }
  const imgEnd: number = rawBody.indexOf('>', imgIndex);
  if (imgEnd < 0) {
    return '';
  }
  return readTagAttr(rawBody.substring(imgIndex, imgEnd + 1), 'img', 'src');
}

/** 作者：dc:creator → Atom author/name → RSS author。 */
function firstAuthor(block: string, isAtom: boolean): string {
  const creator: string = readTagText(block, 'dc:creator');
  if (creator.length > 0) {
    return stripTags(decodeEntities(creator));
  }
  if (isAtom) {
    const authorBlock: string = readTagText(block, 'author');
    const name: string = readTagText(authorBlock, 'name');
    if (name.length > 0) {
      return stripTags(decodeEntities(name));
    }
  }
  return stripTags(decodeEntities(readTagText(block, 'author')));
}

function parseArticle(block: string, isAtom: boolean): ParsedArticle {
  const title: string = stripTags(decodeEntities(readTagText(block, 'title')));
  let link: string = isAtom ? readAtomLink(block) : readTagText(block, 'link');
  if (link.length === 0) {
    link = readTagText(block, 'guid');
  }
  const rawSummary: string = isAtom ? readTagText(block, 'summary') : readTagText(block, 'description');
  const rawContent: string = isAtom ? readTagText(block, 'content') : readTagText(block, 'content:encoded');
  let dateText: string = isAtom
    ? (readTagText(block, 'updated').length > 0 ? readTagText(block, 'updated') : readTagText(block, 'published'))
    : readTagText(block, 'pubDate');
  if (dateText.length === 0) {
    // RSS 1.0 / RDF 常用 dc:date；部分 RSS 2.0 也会带。
    dateText = readTagText(block, 'dc:date');
  }
  const summarySource: string = rawSummary.length > 0 ? rawSummary : rawContent;
  const summary: string = truncate(stripTags(decodeEntities(summarySource)), RssConstants.SUMMARY_MAX_CHARS);
  const bodySource: string = rawContent.length > 0 ? rawContent : rawSummary;
  const content: string = stripTags(decodeEntities(bodySource));
  const contentHtml: string = basicCleanHtml(htmlSource(bodySource));
  const imageUrl: string = firstImageUrl(block, bodySource);
  const author: string = firstAuthor(block, isAtom);
  const enclosures: Enclosure[] = parseEnclosures(block, isAtom);
  return new ParsedArticle(title, link.trim(), summary, content, parseDate(dateText), imageUrl, author,
    contentHtml, enclosures);
}

/**
 * 判断正文是「真 HTML」还是「被实体编码的 HTML」：
 * 含真实标签（'<'）时原样返回（避免把 &quot; 解成引号而破坏属性）；
 * 否则按实体解码（description 常把标签写成 &lt;p&gt;）。
 */
function htmlSource(input: string): string {
  return input.indexOf('<') >= 0 ? input : decodeEntities(input);
}

/** 解析一份 feed 文档；既支持 RSS 2.0（item）也支持 Atom 1.0（entry）。 */
export function parseFeed(xml: string): ParsedFeed {
  const items: string[] = findBlocks(xml, 'item');
  const entries: string[] = findBlocks(xml, 'entry');
  const isAtom: boolean = entries.length > 0 && items.length === 0;
  const blocks: string[] = isAtom ? entries : items;

  const headToken: string = isAtom ? '<entry' : '<item';
  const headIndex: number = blocks.length > 0 ? xml.indexOf(headToken) : -1;
  const head: string = xml.substring(0, headIndex >= 0 ? headIndex : xml.length);

  const title: string = stripTags(decodeEntities(readTagText(head, 'title')));
  const siteUrl: string = isAtom ? readAtomLink(head) : readTagText(head, 'link');

  const articles: ParsedArticle[] = [];
  const limit: number = blocks.length < RssConstants.MAX_ARTICLES_PER_FEED
    ? blocks.length
    : RssConstants.MAX_ARTICLES_PER_FEED;
  for (let i = 0; i < limit; i += 1) {
    articles.push(parseArticle(blocks[i], isAtom));
  }
  return new ParsedFeed(title, siteUrl, articles);
}
