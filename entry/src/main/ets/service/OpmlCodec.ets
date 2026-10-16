/*
 * OpmlCodec.ets — OPML 2.0 的纯文本编解码（无副作用）。
 *
 * OPML 的订阅源一律是 <outline type="rss" text="..." xmlUrl="..." htmlUrl="..."/>，
 * 分组是带子节点、没有 xmlUrl 的 outline —— 所以我们只收集带 xmlUrl 的那些，天然跳过分组节点。
 */

import { decodeEntities } from './RssParser';
import { FeedSource } from '../model/Feed';
import { OpmlConstants } from '../common/constants/RssConstants';

/** 导入时解析出的一条订阅源。 */
export class OpmlEntry {
  readonly title: string;
  readonly xmlUrl: string;
  readonly htmlUrl: string;
  /** 所属分组（来自嵌套的父 outline）；空串表示未分组。 */
  readonly group: string;

  constructor(title: string, xmlUrl: string, htmlUrl: string, group: string = '') {
    this.title = title;
    this.xmlUrl = xmlUrl;
    this.htmlUrl = htmlUrl;
    this.group = group;
  }
}

/** 读取开标签里的属性值；要求属性名前面是空格或 '<'，避免 xmlUrl 匹配到 url。 */
function readAttribute(header: string, name: string): string {
  const token: string = name + '=';
  let from: number = 0;
  while (from < header.length) {
    const index: number = header.indexOf(token, from);
    if (index < 0) {
      return '';
    }
    const previous: string = index > 0 ? header.charAt(index - 1) : '<';
    if (previous !== ' ' && previous !== '\t' && previous !== '\n' && previous !== '<') {
      from = index + token.length;
      continue;
    }
    let rest: string = header.substring(index + token.length).trim();
    const quote: string = rest.charAt(0);
    if (quote !== '"' && quote !== "'") {
      return '';
    }
    rest = rest.substring(1);
    const endQuote: number = rest.indexOf(quote);
    if (endQuote < 0) {
      return '';
    }
    return decodeEntities(rest.substring(0, endQuote)).trim();
  }
  return '';
}

const CLOSE_OUTLINE: string = '</outline>';

/**
 * 解析 OPML：返回所有带 xmlUrl 的条目（自动去重、跳过分组节点）。
 *
 * 分组用嵌套的父 outline 表达（父节点没有 xmlUrl），所以这里用一个栈按标签顺序维护层级：
 * 进入 outline 压栈、遇到 </outline> 出栈，条目的分组取其父节点名。
 */
export function parseOpml(xml: string): OpmlEntry[] {
  const entries: OpmlEntry[] = [];
  const stack: string[] = [];
  let from: number = 0;
  while (from < xml.length) {
    const openIndex: number = xml.indexOf('<outline', from);
    const closeIndex: number = xml.indexOf(CLOSE_OUTLINE, from);
    if (openIndex < 0 && closeIndex < 0) {
      break;
    }
    if (openIndex < 0 || (closeIndex >= 0 && closeIndex < openIndex)) {
      if (stack.length > 0) {
        stack.pop();
      }
      from = closeIndex + CLOSE_OUTLINE.length;
      continue;
    }
    const end: number = xml.indexOf('>', openIndex);
    if (end < 0) {
      break;
    }
    const header: string = xml.substring(openIndex, end + 1);
    const selfClosing: boolean = header.charAt(header.length - 2) === '/';
    const xmlUrl: string = readAttribute(header, 'xmlUrl');
    const title: string = readAttribute(header, 'title');
    const text: string = readAttribute(header, 'text');
    const name: string = title.length > 0 ? title : text;
    if (xmlUrl.length > 0) {
      const group: string = stack.length > 0 ? stack[stack.length - 1] : '';
      if (!hasEntry(entries, xmlUrl)) {
        entries.push(new OpmlEntry(name, xmlUrl, readAttribute(header, 'htmlUrl'), group));
      }
    } else {
      stack.push(name);
      if (selfClosing) {
        stack.pop();
      }
    }
    from = end + 1;
  }
  return entries;
}

function hasEntry(entries: OpmlEntry[], xmlUrl: string): boolean {
  for (let i = 0; i < entries.length; i += 1) {
    if (entries[i].xmlUrl === xmlUrl) {
      return true;
    }
  }
  return false;
}

function escapeAttribute(value: string): string {
  let out: string = value;
  out = out.split('&').join('&amp;');
  out = out.split('<').join('&lt;');
  out = out.split('>').join('&gt;');
  out = out.split('"').join('&quot;');
  return out;
}

function feedOutline(feed: FeedSource, indent: string): string {
  let line: string = indent + '<outline type="rss"';
  line += ' text="' + escapeAttribute(feed.title) + '"';
  line += ' title="' + escapeAttribute(feed.title) + '"';
  line += ' xmlUrl="' + escapeAttribute(feed.url) + '"';
  if (feed.siteUrl.length > 0) {
    line += ' htmlUrl="' + escapeAttribute(feed.siteUrl) + '"';
  }
  line += '/>';
  return line;
}

/** 生成 OPML 2.0 文档；分组用嵌套 outline 表达，未分组的直接平铺在 body 下。 */
export function buildOpml(feeds: FeedSource[]): string {
  const lines: string[] = [];
  lines.push('<?xml version="1.0" encoding="UTF-8"?>');
  lines.push('<opml version="2.0">');
  lines.push('  <head>');
  lines.push('    <title>' + escapeAttribute(OpmlConstants.DOC_TITLE) + '</title>');
  lines.push('  </head>');
  lines.push('  <body>');

  const groupNames: string[] = [];
  for (let i = 0; i < feeds.length; i += 1) {
    const name: string = feeds[i].group;
    if (name.length > 0 && groupNames.indexOf(name) < 0) {
      groupNames.push(name);
    }
  }
  for (let g = 0; g < groupNames.length; g += 1) {
    lines.push('    <outline text="' + escapeAttribute(groupNames[g]) + '">');
    for (let i = 0; i < feeds.length; i += 1) {
      if (feeds[i].group === groupNames[g]) {
        lines.push(feedOutline(feeds[i], '      '));
      }
    }
    lines.push('    </outline>');
  }
  for (let i = 0; i < feeds.length; i += 1) {
    if (feeds[i].group.length === 0) {
      lines.push(feedOutline(feeds[i], '    '));
    }
  }

  lines.push('  </body>');
  lines.push('</opml>');
  return lines.join('\n');
}
