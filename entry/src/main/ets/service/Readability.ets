/*
 * Readability.ets — Readability 式正文提取（客户端、无 DOM 依赖）。
 *
 * 思路（简化的 Mozilla Readability）：
 *   1. 解析为节点树（HtmlDom）；
 *   2. 对「段落型」块级元素按文本长度 / 逗号数 / 链接密度打分，分数向父、祖父传播；
 *   3. 取分最高的节点为主容器，序列化并交给 HtmlSanitizer 净化；
 *   4. 分数过低 / 结果过短时退回「整页去壳留块结构」的兜底。
 * 目标是「留下能读的正文」，不追求与浏览器版 Readability 完全一致。
 */

import { HtmlNode, parseHtml, findFirst, DROP_WITH_CONTENT } from './HtmlDom';
import { sanitizeNode, sanitizeFragment } from './HtmlSanitizer';
import { toPlainText } from '../common/utils/HtmlText';
import { ReaderConstants } from '../common/constants/RssConstants';

/** 参与打分的块级标签。 */
const BLOCK_TAGS: string[] = ['p', 'div', 'section', 'article', 'blockquote', 'pre', 'td', 'li', 'main'];

/** 分类权重：正向（正文容器）/ 负向（导航、广告、相关阅读等）。 */
const POSITIVE_HINTS: string[] = ['article', 'content', 'post', 'entry', 'main', 'body', 'story', 'text'];
const NEGATIVE_HINTS: string[] = [
  'comment', 'sidebar', 'footer', 'nav', 'menu', 'share', 'related',
  'ad', 'ads', 'promo', 'sponsor', 'breadcrumb', 'pagination', 'widget'
];

function isBlock(tag: string): boolean {
  return BLOCK_TAGS.indexOf(tag) >= 0;
}

/** 类名 / id 的分类权重（>1 加成，<1 降权）。 */
function classWeight(node: HtmlNode): number {
  const hint: string = (node.attr('class') + ' ' + node.attr('id')).toLowerCase();
  if (hint.length === 0) {
    return 1;
  }
  for (let i = 0; i < NEGATIVE_HINTS.length; i += 1) {
    if (hint.indexOf(NEGATIVE_HINTS[i]) >= 0) {
      return 0.3;
    }
  }
  for (let i = 0; i < POSITIVE_HINTS.length; i += 1) {
    if (hint.indexOf(POSITIVE_HINTS[i]) >= 0) {
      return 1.6;
    }
  }
  return 1;
}

/** 逗号 / 顿号数量：中文正文的粗略信号。 */
function commaCount(text: string): number {
  let n: number = 0;
  for (let i = 0; i < text.length; i += 1) {
    const c: string = text.charAt(i);
    if (c === ',' || c === '，' || c === '。' || c === ';' || c === '；') {
      n += 1;
    }
  }
  return n;
}

/** 是否是「连内容一起丢弃」的标签（script/style 等）。 */
function isDroppedTag(tag: string): boolean {
  return DROP_WITH_CONTENT.indexOf(tag) >= 0;
}

/** 子树指标：文本长度 / 标点数量 / 链接文本长度。 */
class NodeMetrics {
  textLen: number = 0;
  commas: number = 0;
  linkLen: number = 0;
}

/** 后序遍历栈项（显式栈，避免深文档递归爆栈）。 */
class WalkItem {
  readonly node: HtmlNode;
  readonly expanded: boolean;

  constructor(node: HtmlNode, expanded: boolean) {
    this.node = node;
    this.expanded = expanded;
  }
}

/**
 * 单遍迭代后序收集指标。
 *
 * 原来的实现对每个候选块都要递归调用一次 textContent() + linkTextLength()，
 * 复杂度是 O(n · depth) 且会产生大量临时字符串；这里每个节点只算一次。
 */
function collectMetrics(root: HtmlNode): Map<HtmlNode, NodeMetrics> {
  const metrics: Map<HtmlNode, NodeMetrics> = new Map<HtmlNode, NodeMetrics>();
  const stack: WalkItem[] = [new WalkItem(root, false)];
  while (stack.length > 0) {
    const popped: WalkItem | undefined = stack.pop();
    if (popped === undefined) {
      continue;
    }
    const node: HtmlNode = popped.node;
    if (node.isText()) {
      const m: NodeMetrics = new NodeMetrics();
      const parent: HtmlNode | undefined = node.parent;
      if (parent === undefined || !isDroppedTag(parent.tag)) {
        m.textLen = node.text.length;
        m.commas = commaCount(node.text);
      }
      metrics.set(node, m);
      continue;
    }
    if (!popped.expanded) {
      stack.push(new WalkItem(node, true));
      for (let i = 0; i < node.children.length; i += 1) {
        stack.push(new WalkItem(node.children[i], false));
      }
      continue;
    }
    const m: NodeMetrics = new NodeMetrics();
    if (!isDroppedTag(node.tag)) {
      for (let i = 0; i < node.children.length; i += 1) {
        const child: NodeMetrics | undefined = metrics.get(node.children[i]);
        if (child !== undefined) {
          m.textLen += child.textLen;
          m.commas += child.commas;
          m.linkLen += child.linkLen;
        }
      }
      if (node.tag === 'a') {
        m.linkLen = m.textLen;
      }
    }
    metrics.set(node, m);
  }
  return metrics;
}

function addScore(scores: Map<HtmlNode, number>, node: HtmlNode, delta: number): void {
  const current: number | undefined = scores.get(node);
  scores.set(node, (current === undefined ? 0 : current) + delta);
}

/** 给整棵树打分；返回得分最高的节点。 */
function bestCandidate(root: HtmlNode, metrics: Map<HtmlNode, NodeMetrics>): HtmlNode | undefined {
  const scores: Map<HtmlNode, number> = new Map<HtmlNode, number>();
  const stack: HtmlNode[] = root.children.slice();
  let best: HtmlNode | undefined = undefined;
  let bestScore: number = 0;
  while (stack.length > 0) {
    const popped: HtmlNode | undefined = stack.pop();
    if (popped === undefined) {
      continue;
    }
    const node: HtmlNode = popped;
    for (let i = 0; i < node.children.length; i += 1) {
      if (!node.children[i].isText()) {
        stack.push(node.children[i]);
      }
    }
    if (node.isText() || !isBlock(node.tag)) {
      continue;
    }
    const m: NodeMetrics | undefined = metrics.get(node);
    if (m === undefined) {
      continue;
    }
    const length: number = m.textLen;
    if (length < 25) {
      continue;
    }
    const density: number = length > 0 ? m.linkLen / length : 0;
    const base: number = 1 + m.commas + Math.min(length / 100, 3);
    const score: number = base * (1 - density) * classWeight(node);
    if (score <= 0) {
      continue;
    }
    addScore(scores, node, score);
    const parent: HtmlNode | undefined = node.parent;
    if (parent !== undefined) {
      addScore(scores, parent, score);
      const grand: HtmlNode | undefined = parent.parent;
      if (grand !== undefined) {
        addScore(scores, grand, score / 2);
      }
    }
    if (score > bestScore) {
      bestScore = score;
      best = node;
    }
  }
  // 若最高分落在传播出来的父节点上，可能比原始段落更完整，取传播得分最高的容器。
  let top: HtmlNode | undefined = best;
  let topScore: number = bestScore;
  scores.forEach((value: number, key: HtmlNode) => {
    if (key.tag !== '#root' && key.tag !== 'html' && key.tag !== 'body' && value > topScore) {
      topScore = value;
      top = key;
    }
  });
  return top;
}

/** 主容器若是 html/body 这类，取其得分最高的子节点。 */
function refineCandidate(root: HtmlNode, candidate: HtmlNode, metrics: Map<HtmlNode, NodeMetrics>): HtmlNode {
  if (candidate.tag !== 'html' && candidate.tag !== 'body' && candidate.tag !== '#root') {
    return candidate;
  }
  let best: HtmlNode | undefined = undefined;
  let bestLen: number = 0;
  for (let i = 0; i < candidate.children.length; i += 1) {
    const child: HtmlNode = candidate.children[i];
    if (child.isText()) {
      continue;
    }
    const m: NodeMetrics | undefined = metrics.get(child);
    const len: number = m === undefined ? 0 : m.textLen;
    if (len > bestLen) {
      bestLen = len;
      best = child;
    }
  }
  return best !== undefined ? best : candidate;
}

/** body 节点（优先取真 body，取不到用根）。 */
function bodyOf(root: HtmlNode): HtmlNode {
  const body: HtmlNode | undefined = findFirst(root, 'body');
  return body !== undefined ? body : root;
}

/** feed 正文是否带块级结构（只有纯文本的 description 不算，需联网抓全文）。 */
function hasBlockMarkup(html: string): boolean {
  const lower: string = html.toLowerCase();
  return lower.indexOf('<p') >= 0 || lower.indexOf('<div') >= 0 || lower.indexOf('<article') >= 0
    || lower.indexOf('<section') >= 0 || lower.indexOf('<h1') >= 0 || lower.indexOf('<h2') >= 0
    || lower.indexOf('<ul') >= 0 || lower.indexOf('<figure') >= 0 || lower.indexOf('<br') >= 0;
}

/** 全部 `<a>` 标签内的文本长度（用于识别「只有链接」的正文）；超过 limit 立即返回。 */
function linkTextLengthOf(html: string, limit: number): number {
  const lower: string = html.toLowerCase();
  let total: number = 0;
  let cursor: number = 0;
  while (cursor < lower.length) {
    const start: number = lower.indexOf('<a', cursor);
    if (start < 0) {
      break;
    }
    const next: string = lower.charAt(start + 2);
    // 排除 <article / <abbr 这类前缀相同的标签。
    if (next !== ' ' && next !== '>' && next !== '\n' && next !== '\t') {
      cursor = start + 2;
      continue;
    }
    const openEnd: number = lower.indexOf('>', start);
    if (openEnd < 0) {
      break;
    }
    const close: number = lower.indexOf('</a>', openEnd + 1);
    if (close < 0) {
      break;
    }
    total += toPlainText(html.substring(openEnd + 1, close)).length;
    if (total > limit) {
      return total;
    }
    cursor = close + '</a>'.length;
  }
  return total;
}

/**
 * 判断 feed 自带 HTML 是否值得直接当正文：需要有块级结构，且链接文本占比不高。
 * Hacker News（hnrss）的 description 只有 "Article URL / Comments URL / Points" 这类
 * 链接堆，不能当正文用，否则阅读器里只剩几个链接、看不到原文内容。
 */
export function hasBodyContent(html: string): boolean {
  if (html.length === 0 || !hasBlockMarkup(html)) {
    return false;
  }
  const plain: string = toPlainText(html);
  if (plain.length < ReaderConstants.MIN_FEED_BODY_CHARS) {
    return false;
  }
  const limit: number = plain.length * ReaderConstants.MAX_FEED_BODY_LINK_RATIO;
  return linkTextLengthOf(html, limit) <= limit;
}

/**
 * 从原始 HTML 提取正文片段（已净化）。
 * baseUrl 用于把相对图片 / 链接绝对化。
 */
export function extractReadable(html: string, baseUrl: string): string {
  const source: string = html.length > ReaderConstants.MAX_SOURCE_HTML_CHARS
    ? html.substring(0, ReaderConstants.MAX_SOURCE_HTML_CHARS)
    : html;
  let root: HtmlNode;
  try {
    root = parseHtml(source);
  } catch (err) {
    return '';
  }
  const body: HtmlNode = bodyOf(root);
  // 一次后序遍历把每个节点的文本 / 标点 / 链接长度算好，下面打分与长度判断共用。
  const metrics: Map<HtmlNode, NodeMetrics> = collectMetrics(body);

  let candidate: HtmlNode | undefined = bestCandidate(body, metrics);
  if (candidate !== undefined) {
    candidate = refineCandidate(body, candidate, metrics);
  }

  let fragment: string = '';
  if (candidate !== undefined) {
    fragment = sanitizeNode(candidate, baseUrl);
  }
  const measured: NodeMetrics | undefined = metrics.get(candidate === undefined ? body : candidate);
  const textLen: number = measured === undefined ? 0 : measured.textLen;
  if (fragment.length === 0 || textLen < ReaderConstants.MIN_CONTENT_SCORE) {
    // 兜底：整页去壳，保留块结构（仍远优于纯文本）。
    fragment = sanitizeFragment(body, baseUrl);
  }
  return truncateHtml(fragment);
}

/** 片段超长时按字符截断（尽量在标签外截断，避免破坏结构）。 */
function truncateHtml(fragment: string): string {
  if (fragment.length <= ReaderConstants.MAX_READER_HTML_CHARS) {
    return fragment;
  }
  const cut: string = fragment.substring(0, ReaderConstants.MAX_READER_HTML_CHARS);
  const lastClose: number = cut.lastIndexOf('>');
  return lastClose > 0 ? cut.substring(0, lastClose + 1) : cut;
}
