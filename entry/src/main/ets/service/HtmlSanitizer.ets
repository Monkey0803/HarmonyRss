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
  'a', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'th', 'td', 'caption', 'colgroup', 'col',
  // 内嵌媒体：播客音频、视频、以及 media 的子标签（iframe 单独白名单处理，见 serializeEmbed）
  'video', 'audio', 'track'
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
  if (tag === 'video') {
    return ['src', 'poster', 'controls', 'preload', 'width', 'height', 'playsinline'];
  }
  if (tag === 'audio') {
    return ['src', 'controls', 'preload'];
  }
  if (tag === 'track') {
    return ['src', 'kind', 'srclang', 'label', 'default'];
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
/** srcset 里挑选的目标宽度（px）：手机阅读场景取「够清晰又不浪费流量」的一档。 */
const SRCSET_TARGET_WIDTH: number = 1080;

/**
 * 从 srcset 里挑一个候选：按描述符宽度（如 `a.jpg 320w`）选最接近目标宽度的一档；
 * 没有宽度描述符（如 `a.jpg 2x`）时退回第一个候选。
 * 原来只取第一项，很多站点第一项是 320w 的小图，正文里会糊。
 */
function urlFromSrcset(value: string): string {
  const text: string = value.trim();
  if (text.length === 0) {
    return '';
  }
  const parts: string[] = text.split(',');
  let bestUrl: string = '';
  let bestGap: number = Number.MAX_VALUE;
  let fallback: string = '';
  for (let i = 0; i < parts.length; i += 1) {
    const candidate: string = parts[i].trim();
    if (candidate.length === 0) {
      continue;
    }
    const space: number = candidate.search(/\s/);
    const url: string = (space < 0 ? candidate : candidate.substring(0, space)).trim();
    if (url.length === 0) {
      continue;
    }
    if (fallback.length === 0) {
      fallback = url;
    }
    const descriptor: string = space < 0 ? '' : candidate.substring(space).trim();
    if (descriptor.length === 0 || descriptor.charAt(descriptor.length - 1) !== 'w') {
      continue;
    }
    const width: number = Number(descriptor.substring(0, descriptor.length - 1));
    if (!Number.isFinite(width)) {
      continue;
    }
    const gap: number = Math.abs(width - SRCSET_TARGET_WIDTH);
    if (gap < bestGap) {
      bestGap = gap;
      bestUrl = url;
    }
  }
  return bestUrl.length > 0 ? bestUrl : fallback;
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
    urlFromSrcset(node.attr('data-srcset')),
    urlFromSrcset(node.attr('srcset'))
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

/** 允许内嵌的播放域（iframe）：只放行 https 且域名命中的嵌入，其余一律丢弃。 */
const IFRAME_ALLOW_HOSTS: string[] = [
  'www.youtube.com', 'youtube.com', 'youtu.be', 'www.youtube-nocookie.com',
  'player.vimeo.com', 'vimeo.com',
  'player.bilibili.com', 'www.bilibili.com',
  'open.spotify.com', 'w.soundcloud.com'
];

/** 判断 iframe 的地址是否在放行名单里（https + 域名后缀匹配）。 */
function isAllowedEmbed(rawUrl: string, baseUrl: string): string {
  const url: string = resolveUrl(baseUrl, rawUrl);
  if (url.length === 0 || url.indexOf('https://') !== 0) {
    return '';
  }
  const hostStart: number = 'https://'.length;
  const rest: string = url.substring(hostStart);
  const slash: number = rest.indexOf('/');
  const host: string = (slash < 0 ? rest : rest.substring(0, slash)).toLowerCase();
  const hostNoPort: string = host.indexOf(':') < 0 ? host : host.substring(0, host.indexOf(':'));
  for (let i = 0; i < IFRAME_ALLOW_HOSTS.length; i += 1) {
    const allowed: string = IFRAME_ALLOW_HOSTS[i];
    if (hostNoPort === allowed || hostNoPort.endsWith('.' + allowed)) {
      return url;
    }
  }
  return '';
}

/** 内嵌播放器的安全序列化：只保留绝对化后的 src 与少量必要属性。 */
function serializeEmbed(node: HtmlNode, baseUrl: string): string {
  const src: string = isAllowedEmbed(node.attr('src'), baseUrl);
  if (src.length === 0) {
    return '';
  }
  return '<iframe src="' + decodeAndEscape(src) + '" loading="lazy" allowfullscreen ' +
    'referrerpolicy="no-referrer" frameborder="0"></iframe>';
}

/**
 * 序列化一个节点子树为安全 HTML 片段。
 * 内部走单次 DFS + 数组缓冲：避免递归拼串的 O(n · depth) 开销，也不会因深嵌套爆栈。
 */
export function sanitizeNode(node: HtmlNode, baseUrl: string): string {
  const out: string[] = [];
  emitNode(node, baseUrl, out);
  return out.join('');
}

function emitNode(node: HtmlNode, baseUrl: string, out: string[]): void {
  if (node.isText()) {
    out.push(decodeAndEscape(node.text));
    return;
  }
  const tag: string = node.tag;
  if (tag === 'iframe') {
    // 先于 isDropTag 判断：白名单内的播放域要保留（其余 iframe 丢弃）
    const embed: string = serializeEmbed(node, baseUrl);
    if (embed.length > 0) {
      out.push(embed);
    }
    return;
  }
  if (isDropTag(tag)) {
    return;
  }
  // 空段落 / 空容器没有阅读价值，还会在正文里撑出空行：
  // 先序列化子节点，再判断里面到底有没有「看得见」的东西（文字 / 媒体 / 分隔线）。
  // 只包图片的链接（缩略图 / 头像 / 点图跳原站）在阅读器里没有意义，
  // 去掉 <a> 只留 <img>：点图片交给大图查看器，也不会把页面导航出去。
  if (tag === 'a') {
    const linkParts: string[] = [];
    emitChildren(node, baseUrl, linkParts);
    const linkInner: string = linkParts.join('');
    const withoutImages: string = linkInner
      .replace(/<img[^>]*>/g, '')
      .replace(/<\/?picture>/g, '')
      .trim();
    if (linkInner.indexOf('<img') >= 0 && withoutImages.length === 0) {
      out.push(linkInner);
      return;
    }
    if (hasRenderedContent(linkInner)) {
      out.push('<a' + serializeAttrs(node, baseUrl) + '>' + linkInner + '</a>');
    }
    return;
  }

  if (tag === 'p' || tag === 'div' || tag === 'span' || tag === 'section') {
    const innerParts: string[] = [];
    emitChildren(node, baseUrl, innerParts);
    const inner: string = innerParts.join('');
    if (!hasRenderedContent(inner)) {
      return;
    }
    // 很多站点（含少数派）的正文用 div 当段落：纯文字的 div 归一成 p，
    // 这样段落间距与「首行缩进」等基于 p 的排版规则才能生效。
    const outTag: string = (tag === 'div' && !hasBlockMarkup(inner)) ? 'p' : tag;
    out.push('<' + outTag + serializeAttrs(node, baseUrl) + '>' + inner + '</' + outTag + '>');
    return;
  }
  if (tag === 'img') {
    // img 单独处理：合并懒加载属性、绝对化地址。
    out.push(serializeImage(node, baseUrl));
    return;
  }
  if (!isAllowedTag(tag)) {
    // 未知标签：去壳留内容。
    emitChildren(node, baseUrl, out);
    return;
  }
  const attrs: string = serializeAttrs(node, baseUrl);
  if (isVoidOut(tag)) {
    out.push('<' + tag + attrs + '>');
    return;
  }
  out.push('<' + tag + attrs + '>');
  emitChildren(node, baseUrl, out);
  out.push('</' + tag + '>');
}

/** 片段里是否含块级标签（决定 div 能否安全地归一成 p）。 */
function hasBlockMarkup(html: string): boolean {
  const blocks: string[] = [
    '<div', '<p', '<ul', '<ol', '<li', '<table', '<figure', '<figcaption',
    '<h1', '<h2', '<h3', '<h4', '<h5', '<h6', '<blockquote', '<pre',
    '<img', '<video', '<audio', '<iframe', '<picture', '<hr'
  ];
  for (let i = 0; i < blocks.length; i += 1) {
    if (html.indexOf(blocks[i]) >= 0) {
      return true;
    }
  }
  return false;
}

/** 序列化结果里是否有可见内容（文字 / 媒体 / 表格 / 分隔线）。 */
function hasRenderedContent(html: string): boolean {
  if (html.length === 0) {
    return false;
  }
  const visual: string[] = ['<img', '<video', '<audio', '<iframe', '<hr', '<picture', '<table', '<canvas'];
  for (let i = 0; i < visual.length; i += 1) {
    if (html.indexOf(visual[i]) >= 0) {
      return true;
    }
  }
  // 去掉标签后还剩非空白字符，才算有正文。
  return html.replace(/<[^>]*>/g, '').replace(/\s+/g, '').length > 0;
}

function emitChildren(node: HtmlNode, baseUrl: string, out: string[]): void {
  for (let i = 0; i < node.children.length; i += 1) {
    emitNode(node.children[i], baseUrl, out);
  }
}

/** 只净化「子节点」，用于 body / 未知容器这类本身要去壳的节点。 */
export function sanitizeFragment(node: HtmlNode, baseUrl: string): string {
  const out: string[] = [];
  emitChildren(node, baseUrl, out);
  return out.join('');
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
