/*
 * FeedDiscovery.ets — 从站点主页发现订阅地址（feed autodiscovery）。
 *
 * 只解决「用户粘贴的是站点主页、不是 feed 地址」这一种情况：抓到的 HTML 里通常写着
 *   <link rel="alternate" type="application/rss+xml" href="/feed.xml">
 * 这里把这些候选地址找出来（补成绝对地址、去重、保持出现顺序），由调用方逐个试。
 *
 * 只做文本扫描，不引入 HTML 解析器：靠两个正则把 <link …> 标签和它的属性取出来即可。
 */

import { url } from '@kit.ArkTS';

/** <link …> 标签（\b 保证不会连到 <linkage 之类的标签）。 */
const LINK_PATTERN: RegExp = /<link\b[^>]*>/gi;
/** 标签属性：name="value" 或 name='value'。 */
const ATTR_PATTERN: RegExp = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("[^"]*"|'[^']*')/g;

export class FeedDiscovery {
  /** 从 HTML 里找出候选订阅地址；没有则返回空数组。 */
  candidateUrls(document: string, baseUrl: string): string[] {
    const found: string[] = [];
    const seen: Set<string> = new Set();
    LINK_PATTERN.lastIndex = 0;
    let match: RegExpExecArray | null = LINK_PATTERN.exec(document);
    while (match !== null) {
      const attrs: Record<string, string> = parseAttributes(match[0]);
      const rel: string = pick(attrs, 'rel').toLowerCase();
      const type: string = pick(attrs, 'type').toLowerCase();
      const href: string = pick(attrs, 'href');
      if (rel.indexOf('alternate') >= 0 && href.length > 0 && isFeedType(type)) {
        const absolute: string = absoluteUrl(href, baseUrl);
        if (absolute.length > 0 && !seen.has(absolute)) {
          seen.add(absolute);
          found.push(absolute);
        }
      }
      match = LINK_PATTERN.exec(document);
    }
    return found;
  }
}

/** 取属性值；没有返回空串。 */
function pick(attrs: Record<string, string>, name: string): string {
  const value: string | undefined = attrs[name];
  return value === undefined ? '' : value;
}

/** 把标签里的属性解析成小写名 → 值（值已去掉引号）。 */
function parseAttributes(tag: string): Record<string, string> {
  const attrs: Record<string, string> = {};
  ATTR_PATTERN.lastIndex = 0;
  let match: RegExpExecArray | null = ATTR_PATTERN.exec(tag);
  while (match !== null) {
    const name: string = match[1].toLowerCase();
    const quoted: string = match[2];
    attrs[name] = quoted.substring(1, quoted.length - 1);
    match = ATTR_PATTERN.exec(tag);
  }
  return attrs;
}

/** 相对地址补成绝对地址；不是 http(s) 且补不出来时返回空串。 */
function absoluteUrl(href: string, baseUrl: string): string {
  const trimmed: string = href.trim();
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  if (baseUrl.length === 0) {
    return '';
  }
  try {
    return new url.URL(trimmed, baseUrl).toString();
  } catch (err) {
    return '';
  }
}

/** 只认订阅相关类型：RSS / Atom / JSON Feed / RDF。 */
function isFeedType(type: string): boolean {
  if (type.length === 0) {
    return false;
  }
  return type.indexOf('rss') >= 0
    || type.indexOf('atom') >= 0
    || type.indexOf('feed+json') >= 0
    || type === 'application/json'
    || type.indexOf('rdf') >= 0;
}

/** 全局唯一实例。 */
export const feedDiscovery: FeedDiscovery = new FeedDiscovery();
