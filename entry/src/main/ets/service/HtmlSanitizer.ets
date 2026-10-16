/*
 * HtmlSanitizer.ets — 把 HTML 子树序列化为安全的正文片段。
 *
 * 白名单制：只保留阅读需要的标签 / 属性；未知标签「去壳留内容」，
 * script / style / iframe 等危险标签连内容一起丢；相对 URL 用 baseUrl 绝对化。
 * 输出供 Reader 视图内嵌到受控文档里（见 ReaderDocument.ets）。
 */

import { HtmlAttr, HtmlNode, DROP_WITH_CONTENT } from './HtmlDom';
import { decodeEntities } from './RssParser';

/** 允许保留的标签（其余标签去壳留内容）。 */
const ALLOWED_TAGS: string[] = [
  'p', 'br', 'hr', 'div', 'span',
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'ul', 'ol', 'li', 'dl', 'dt', 'dd',
  'blockquote', 'pre', 'code', 'kbd', 'samp',
  'strong', 'b', 'em', 'i', 'u', 's', 'sub', 'sup', 'mark', 'small',
  'figure', 'figcaption', 'img', 'picture',
  'a', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'th', 'td', 'caption', 'colgroup', 'col'
];

/** 输出时按 void 元素处理（不加结束标签）。 */
const VOID_OUT: string[] = ['br', 'hr', 'img', 'source', 'col'];

/** 允许保留的属性（按标签）。'*' 表示所有标签通用。 */
function allowedAttrs(tag: string): string[] {
  if (tag === 'a') {
    return ['href', 'title'];
  }
  if (tag === 'img') {
    return ['src', 'alt', 'title', 'width', 'height'];
  }
  if (tag === 'source') {
    return ['src', 'srcset', 'type'];
  }
  if (tag === 'td' || tag === 'th') {
    return ['colspan', 'rowspan'];
  }
  if (tag === 'col') {
    return ['span'];
  }
  return [];
}

function isAllowedTag(tag: string): boolean {
  return ALLOWED_TAGS.indexOf(tag) >= 0;
}

function isDropTag(tag: string): boolean {
  return DROP_WITH_CONTENT.indexOf(tag) >= 0 || tag === 'head' || tag === 'body' || tag === 'html';
}

function isVoidOut(tag: string): boolean {
  return VOID_OUT.indexOf(tag) >= 0;
}

/** HTML 文本转义（用于文本节点与属性值）。 */
export function escapeHtml(value: string): string {
  let out: string = value;
  out = out.split('&').join('&amp;');
  out = out.split('<').join('&lt;');
  out = out.split('>').join('&gt;');
  out = out.split('"').join('&quot;');
  return out;
}

/**
 * 先解码源里的实体再转义：源文本可能已含 &#39; / &amp; 这类实体，
 * 直接转义会把 '&' 变成 '&amp;'，浏览器就不再解码，导致页面上出现字面 “&#39;”。
 * 先解码回字符再转义可保证「解码一次、转义一次」。
 */
function decodeAndEscape(value: string): string {
  return escapeHtml(decodeEntities(value));
}

/** 取 URL 的 origin（scheme://host[:port]）；失败返回空串。 */
function originOf(url: string): string {
  const scheme: number = url.indexOf('://');
  if (scheme < 0) {
    return '';
  }
  const afterScheme: number = scheme + 3;
  const slash: number = url.indexOf('/', afterScheme);
  return slash < 0 ? url : url.substring(0, slash);
}

function dirOf(url: string): string {
  const q: number = url.indexOf('?');
  const base: string = q < 0 ? url : url.substring(0, q);
  const h: number = base.indexOf('#');
  const clean: string = h < 0 ? base : base.substring(0, h);
  const slash: number = clean.lastIndexOf('/');
  return slash < 0 ? clean : clean.substring(0, slash + 1);
}

/** 去掉路径中的 ./ 与 ../（简化版）。 */
function normalizePath(path: string): string {
  const segments: string[] = path.split('/');
  const out: string[] = [];
  for (let i = 0; i < segments.length; i += 1) {
    const seg: string = segments[i];
    if (seg === '.') {
      continue;
    }
    if (seg === '..') {
      if (out.length > 0) {
        out.pop();
      }
      continue;
    }
    out.push(seg);
  }
  return out.join('/');
}

/** 把相对 URL 解析为绝对 URL；无法解析时原样返回（不太可能是可执行脚本）。 */
export function resolveUrl(base: string, url: string): string {
  const trimmed: string = url.trim();
  if (trimmed.length === 0) {
    return '';
  }
  const lower: string = trimmed.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://') || lower.startsWith('data:')
    || lower.startsWith('mailto:') || lower.startsWith('tel:')) {
    return trimmed;
  }
  if (base.length === 0) {
    return trimmed;
  }
  if (trimmed.startsWith('//')) {
    const schemeEnd: number = base.indexOf('://');
    const scheme: string = schemeEnd < 0 ? 'https:' : base.substring(0, schemeEnd + 1);
    return scheme + trimmed;
  }
  if (trimmed.startsWith('/')) {
    const origin: string = originOf(base);
    return origin.length > 0 ? origin + normalizePath(trimmed) : trimmed;
  }
  if (trimmed.startsWith('#')) {
    return base + trimmed;
  }
  // 相对路径：拼到 base 目录后再整体归一，才能正确消掉 '..'。
  const origin: string = originOf(base);
  const baseDir: string = dirOf(base);
  const basePath: string = origin.length > 0 ? baseDir.substring(origin.length) : baseDir;
  return origin + normalizePath(basePath + trimmed);
}

/** 属性值是否可疑（内联脚本 / javascript: 协议）。 */
function isDangerousValue(value: string): boolean {
  const lower: string = value.trim().toLowerCase();
  return lower.indexOf('javascript:') === 0 || lower.indexOf('vbscript:') === 0
    || lower.indexOf('data:text/html') === 0;
}

/** 真正的图片地址：排除空串与 data:/about:/blob: 占位（懒加载常用 1×1 占位图）。 */
function isRealImageUrl(value: string): boolean {
  const text: string = value.trim();
  if (text.length === 0) {
    return false;
  }
  const lower: string = text.toLowerCase();
  return lower.indexOf('data:') !== 0 && lower.indexOf('about:') !== 0 && lower.indexOf('blob:') !== 0;
}

/** 取 srcset 里的第一个候选地址（"a.png 1x, b.png 2x" → "a.png"）。 */
function firstUrlFromSrcset(value: string): string {
  const text: string = value.trim();
  if (text.length === 0) {
    return '';
  }
  const comma: number = text.indexOf(',');
  const first: string = comma < 0 ? text : text.substring(0, comma);
  let end: number = 0;
  while (end < first.length) {
    const c: string = first.charAt(end);
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
      break;
    }
    end += 1;
  }
  return first.substring(0, end).trim();
}

/**
 * 选出 `<img>` 的真实图片地址，兼容 JS 懒加载：
 * src → data-src → data-original → data-lazy-src → data-actualsrc → srcset/data-srcset 首项。
 * 首选「非占位」的地址（懒加载常用 data: 占位图放在 src 上）。
 */
function pickImageUrl(node: HtmlNode): string {
  const direct: string[] = [
    node.attr('src'),
    node.attr('data-src'),
    node.attr('data-original'),
    node.attr('data-lazy-src'),
    node.attr('data-actualsrc'),
    node.attr('data-original-src')
  ];
  for (let i = 0; i < direct.length; i += 1) {
    if (isRealImageUrl(direct[i])) {
      return direct[i].trim();
    }
  }
  const srcset: string[] = [
    firstUrlFromSrcset(node.attr('data-srcset')),
    firstUrlFromSrcset(node.attr('srcset'))
  ];
  for (let i = 0; i < srcset.length; i += 1) {
    if (isRealImageUrl(srcset[i])) {
      return srcset[i];
    }
  }
  // 兜底：连占位也留着（至少不丢图）。
  for (let i = 0; i < direct.length; i += 1) {
    if (direct[i].trim().length > 0) {
      return direct[i].trim();
    }
  }
  return '';
}

/** `<img>` 的安全属性：统一用选出的 src，并把相对地址绝对化。 */
function serializeImage(node: HtmlNode, baseUrl: string): string {
  let out: string = '<img';
  const chosen: string = pickImageUrl(node);
  if (chosen.length > 0) {
    const resolved: string = resolveUrl(baseUrl, chosen);
    if (resolved.length > 0) {
      out += ' src="' + decodeAndEscape(resolved) + '"';
    }
  }
  const alt: string = node.attr('alt');
  if (alt.length > 0) {
    out += ' alt="' + decodeAndEscape(alt) + '"';
  }
  const title: string = node.attr('title');
  if (title.length > 0) {
    out += ' title="' + decodeAndEscape(title) + '"';
  }
  const width: string = node.attr('width');
  if (width.length > 0) {
    out += ' width="' + decodeAndEscape(width) + '"';
  }
  const height: string = node.attr('height');
  if (height.length > 0) {
    out += ' height="' + decodeAndEscape(height) + '"';
  }
  out += ' loading="lazy">';
  return out;
}

/** 序列化一个节点子树为安全 HTML 片段。 */
export function sanitizeNode(node: HtmlNode, baseUrl: string): string {
  if (node.isText()) {
    return decodeAndEscape(node.text);
  }
  const tag: string = node.tag;
  if (isDropTag(tag)) {
    return '';
  }
  if (tag === 'img') {
    // img 单独处理：合并懒加载属性、绝对化地址。
    return serializeImage(node, baseUrl);
  }
  const inner: string = sanitizeChildren(node, baseUrl);
  if (!isAllowedTag(tag)) {
    // 未知标签：去壳留内容。
    return inner;
  }
  const attrs: string = serializeAttrs(node, baseUrl);
  if (isVoidOut(tag)) {
    return '<' + tag + attrs + '>';
  }
  return '<' + tag + attrs + '>' + inner + '</' + tag + '>';
}

function sanitizeChildren(node: HtmlNode, baseUrl: string): string {
  let out: string = '';
  for (let i = 0; i < node.children.length; i += 1) {
    out += sanitizeNode(node.children[i], baseUrl);
  }
  return out;
}

/** 只净化「子节点」，用于 body / 未知容器这类本身要去壳的节点。 */
export function sanitizeFragment(node: HtmlNode, baseUrl: string): string {
  return sanitizeChildren(node, baseUrl);
}

function serializeAttrs(node: HtmlNode, baseUrl: string): string {
  const allowed: string[] = allowedAttrs(node.tag);
  let out: string = '';
  for (let i = 0; i < node.attrs.length; i += 1) {
    const attr: HtmlAttr = node.attrs[i];
    if (allowed.indexOf(attr.name) < 0) {
      continue;
    }
    if (isDangerousValue(attr.value)) {
      continue;
    }
    let value: string = attr.value;
    if (attr.name === 'href' || attr.name === 'src') {
      value = resolveUrl(baseUrl, value);
      if (value.length === 0) {
        continue;
      }
    }
    out += ' ' + attr.name + '="' + decodeAndEscape(value) + '"';
  }
  return out;
}
