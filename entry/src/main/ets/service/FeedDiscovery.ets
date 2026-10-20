/*
 * FeedDiscovery.ets — 从站点主页发现订阅地址（feed autodiscovery）。
 *
 * 只解决「用户粘贴的是站点主页、不是 feed 地址」这一种情况：抓到的 HTML 里通常写着
 *   <link rel="alternate" type="application/rss+xml" href="/feed.xml">
 * 这里把这些候选地址找出来（补成绝对地址、去重、保持出现顺序），由调用方逐个试。
 *
 * 增强点：
 *   1) 尊重页面里的 <base href>（相对地址按它解析，而不是只按传入的 baseUrl）；
 *   2) <link> 一个都没发现时，追加常见约定路径（/feed、/rss.xml …）作为兜底候选，
 *      提高「站点没写 autodiscovery」时的成功率。
 *
 * 只做文本扫描，不引入 HTML 解析器：靠正则把标签和它的属性取出来即可。
 */

import { url } from '@kit.ArkTS';

/** <link …> 标签（\b 保证不会连到 <linkage 之类的标签）。 */
const LINK_PATTERN: RegExp = /<link\b[^>]*>/gi;
/** <base …> 标签（取 href 作为相对地址解析基准）。 */
const BASE_PATTERN: RegExp = /<base\b[^>]*>/i;
/** 标签属性：name="value" 或 name='value'。 */
const ATTR_PATTERN: RegExp = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("[^"]*"|'[^']*')/g;
/** 常见约定订阅路径（相对站点的兜底候选）。 */
const FALLBACK_PATHS: string[] = [
  'feed', 'feed/', 'rss', 'rss/', 'rss.xml', 'atom.xml', 'feed.xml', 'index.xml', 'feeds/posts/default'
];

export class FeedDiscovery {
  /** 从 HTML 里找出候选订阅地址；没有则返回兜底候选（可能为空）。 */
  candidateUrls(document: string, baseUrl: string): string[] {
    const found: string[] = [];
    const seen: Set<string> = new Set();
    // 优先按页面声明的 <base href> 解析相对地址，没有再用传入的 baseUrl。
    const base: string = resolveBase(document, baseUrl);
    LINK_PATTERN.lastIndex = 0;
    let match: RegExpExecArray | null = LINK_PATTERN.exec(document);
    while (match !== null) {
      const attrs: Record<string, string> = parseAttributes(match[0]);
      const rel: string = pick(attrs, 'rel').toLowerCase();
      const type: string = pick(attrs, 'type').toLowerCase();
      const href: string = pick(attrs, 'href');
      if (rel.indexOf('alternate') >= 0 && href.length > 0 && isFeedType(type)) {
        const absolute: string = absoluteUrl(href, base);
        if (absolute.length > 0 && !seen.has(absolute)) {
          seen.add(absolute);
          found.push(absolute);
        }
      }
      match = LINK_PATTERN.exec(document);
    }
    // 只有完全没发现 <link> 候选时才试探约定路径：避免「已能发现」的站点白跑一堆请求。
    if (found.length === 0) {
      const fallbacks: string[] = fallbackUrls(baseUrl);
      for (let i = 0; i < fallbacks.length; i += 1) {
        if (!seen.has(fallbacks[i])) {
          seen.add(fallbacks[i]);
          found.push(fallbacks[i]);
        }
      }
    }
    return found;
  }
}

/** 解析页面里的 <base href>（相对传入 baseUrl ）；没有则返回 baseUrl。 */
function resolveBase(document: string, baseUrl: string): string {
  const baseTag: RegExpMatchArray | null = document.match(BASE_PATTERN);
  if (baseTag === null || baseTag.length === 0) {
    return baseUrl;
  }
  const attrs: Record<string, string> = parseAttributes(baseTag[0]);
  const href: string = pick(attrs, 'href');
  if (href.length === 0) {
    return baseUrl;
  }
  const absolute: string = absoluteUrl(href, baseUrl);
  return absolute.length > 0 ? absolute : baseUrl;
}

/** 站点 origin（scheme://host[:port]）+ 目录前缀 组合出的常见订阅路径候选。 */
function fallbackUrls(baseUrl: string): string[] {
  const result: string[] = [];
  const origin: string = originOf(baseUrl);
  const dir: string = dirOf(baseUrl);
  for (let i = 0; i < FALLBACK_PATHS.length; i += 1) {
    const path: string = FALLBACK_PATHS[i];
    if (origin.length > 0) {
      result.push(origin + '/' + path);
    }
    if (dir.length > 1) {
      // 站点挂在子目录下（如 /blog/）时，订阅可能就在该目录下。
      result.push(origin + dir + path);
    }
  }
  return result;
}

/** scheme://host[:port]；解析失败返回空串。 */
function originOf(value: string): string {
  try {
    const u: url.URL = new url.URL(value);
    return u.protocol + '//' + u.host;
  } catch (err) {
    return '';
  }
}

/** 目录前缀（含尾部 '/'）；解析失败返回 '/'。 */
function dirOf(value: string): string {
  try {
    const u: url.URL = new url.URL(value);
    const path: string = u.pathname;
    const index: number = path.lastIndexOf('/');
    return index >= 0 ? path.substring(0, index + 1) : '/';
  } catch (err) {
    return '/';
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
