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
  'figure', 'figcaption', 'img', 'picture', 'source',
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
  return dirOf(base) + normalizePath(trimmed);
}

/** 属性值是否可疑（内联脚本 / javascript: 协议）。 */
function isDangerousValue(value: string): boolean {
  const lower: string = value.trim().toLowerCase();
  return lower.indexOf('javascript:') === 0 || lower.indexOf('vbscript:') === 0
    || lower.indexOf('data:text/html') === 0;
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
  if (node.tag === 'img' && out.indexOf(' loading=') < 0) {
    out += ' loading="lazy"';
  }
  return out;
}
