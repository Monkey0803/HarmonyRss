/*
 * HtmlDom.ets — 极简 HTML 解析（token 扫描 + 节点树），供 Readability / HtmlSanitizer 复用。
 *
 * ArkTS 没有 DOM，这里自建一个够用的子集：
 *   - 只处理标签 / 文本 / 注释 / doctype / CDATA；
 *   - 处理 void 元素（自动闭合）与 raw-text 元素（script/style 内容整体吞掉，避免 '<' 破坏解析）；
 *   - 不做 HTML5 容错（不规范嵌套按栈就近闭合），对 feed / 文章页足够稳健。
 * 所有节点是显式 class（无 any / 无动态属性访问），符合 ArkTS 严格模式。
 */

/** 一个 HTML 属性。 */
export class HtmlAttr {
  readonly name: string;
  readonly value: string;

  constructor(name: string, value: string) {
    this.name = name;
    this.value = value;
  }
}

/** 一个 HTML 节点：tag 为空串表示文本节点（内容在 text）。 */
export class HtmlNode {
  tag: string;
  attrs: HtmlAttr[];
  children: HtmlNode[];
  text: string;
  parent: HtmlNode | undefined;

  constructor(tag: string) {
    this.tag = tag;
    this.attrs = [];
    this.children = [];
    this.text = '';
    this.parent = undefined;
  }

  /** 属性值（不存在返回空串）。 */
  attr(name: string): string {
    for (let i = 0; i < this.attrs.length; i += 1) {
      if (this.attrs[i].name === name) {
        return this.attrs[i].value;
      }
    }
    return '';
  }

  isText(): boolean {
    return this.tag.length === 0;
  }
}

/** 自闭合 / void 元素。 */
const VOID_ELEMENTS: string[] = [
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
  'link', 'meta', 'param', 'source', 'track', 'wbr'
];

/** 内容整体吞噬的元素（内部 '<' 不参与解析）。 */
const RAW_TEXT_ELEMENTS: string[] = ['script', 'style', 'textarea', 'title'];

/** 未闭合时遇到同标签可隐式闭合的元素（贴近 HTML5）。 */
const IMPLICIT_CLOSE: string[] = ['li', 'p'];

/** 会被直接丢弃、连内容也不要的元素。 */
// iframe 交给净化器按域名白名单处理（见 HtmlSanitizer.serializeEmbed），这里不再整段丢弃。
export const DROP_WITH_CONTENT: string[] = ['script', 'style', 'noscript', 'template', 'svg', 'canvas'];

function isVoid(tag: string): boolean {
  return VOID_ELEMENTS.indexOf(tag) >= 0;
}

function isRawText(tag: string): boolean {
  return RAW_TEXT_ELEMENTS.indexOf(tag) >= 0;
}

/** 解析标签头部为节点：返回 [node, endIndex]（endIndex 指向 '>' 之后）。 */
class TagParseResult {
  readonly node: HtmlNode;
  readonly end: number;

  constructor(node: HtmlNode, end: number) {
    this.node = node;
    this.end = end;
  }
}

function parseTag(html: string, start: number): TagParseResult {
  const node: HtmlNode = new HtmlNode('');
  let i: number = start + 1;
  let nameEnd: number = i;
  while (nameEnd < html.length) {
    const c: string = html.charAt(nameEnd);
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '/' || c === '>') {
      break;
    }
    nameEnd += 1;
  }
  node.tag = html.substring(i, nameEnd).toLowerCase();
  i = nameEnd;

  while (i < html.length) {
    const c: string = html.charAt(i);
    if (c === '>') {
      i += 1;
      break;
    }
    if (c === '/' ) {
      i += 1;
      continue;
    }
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
      i += 1;
      continue;
    }
    // 属性名
    let attrNameEnd: number = i;
    while (attrNameEnd < html.length) {
      const ac: string = html.charAt(attrNameEnd);
      if (ac === '=' || ac === '>' || ac === ' ' || ac === '\t' || ac === '\n' || ac === '\r') {
        break;
      }
      attrNameEnd += 1;
    }
    const attrName: string = html.substring(i, attrNameEnd).toLowerCase();
    i = attrNameEnd;
    let attrValue: string = '';
    // 跳过空白
    while (i < html.length) {
      const wc: string = html.charAt(i);
      if (wc === ' ' || wc === '\t' || wc === '\n' || wc === '\r') {
        i += 1;
      } else {
        break;
      }
    }
    if (i < html.length && html.charAt(i) === '=') {
      i += 1;
      while (i < html.length) {
        const wc: string = html.charAt(i);
        if (wc === ' ' || wc === '\t' || wc === '\n' || wc === '\r') {
          i += 1;
        } else {
          break;
        }
      }
      if (i < html.length) {
        const quote: string = html.charAt(i);
        if (quote === '"' || quote === "'") {
          i += 1;
          const vEnd: number = html.indexOf(quote, i);
          if (vEnd < 0) {
            attrValue = html.substring(i);
            i = html.length;
          } else {
            attrValue = html.substring(i, vEnd);
            i = vEnd + 1;
          }
        } else {
          let vEnd: number = i;
          while (vEnd < html.length) {
            const vc: string = html.charAt(vEnd);
            if (vc === ' ' || vc === '\t' || vc === '\n' || vc === '\r' || vc === '>') {
              break;
            }
            vEnd += 1;
          }
          attrValue = html.substring(i, vEnd);
          i = vEnd;
        }
      }
    }
    if (attrName.length > 0) {
      node.attrs.push(new HtmlAttr(attrName, attrValue));
    }
  }
  return new TagParseResult(node, i);
}

/** 解析 HTML 字符串为节点树；返回虚拟根节点（tag 为 '#root'）。 */
export function parseHtml(html: string): HtmlNode {
  const root: HtmlNode = new HtmlNode('#root');
  const stack: HtmlNode[] = [root];
  let i: number = 0;
  // 原文小写副本按需创建一次：查找 </script> 这类结束标签不能对整篇反复 toLowerCase()。
  let lower: string = '';
  let lowerReady: boolean = false;
  while (i < html.length) {
    const lt: number = html.indexOf('<', i);
    if (lt < 0) {
      appendText(stack[stack.length - 1], html.substring(i));
      break;
    }
    if (lt > i) {
      appendText(stack[stack.length - 1], html.substring(i, lt));
    }
    // 注释
    if (html.startsWith('<!--', lt)) {
      const end: number = html.indexOf('-->', lt + 4);
      i = end < 0 ? html.length : end + 3;
      continue;
    }
    // CDATA（必须在通用 <! 判断之前：否则会被当成 doctype 跳掉）
    if (html.startsWith('<![CDATA[', lt)) {
      const end: number = html.indexOf(']]>', lt + 9);
      const inner: string = end < 0 ? html.substring(lt + 9) : html.substring(lt + 9, end);
      appendText(stack[stack.length - 1], inner);
      i = end < 0 ? html.length : end + 3;
      continue;
    }
    // doctype / 其它 <! >
    if (html.charAt(lt + 1) === '!') {
      const end: number = html.indexOf('>', lt);
      i = end < 0 ? html.length : end + 1;
      continue;
    }
    // 结束标签
    if (html.charAt(lt + 1) === '/') {
      const gt: number = html.indexOf('>', lt);
      const name: string = html.substring(lt + 2, gt < 0 ? html.length : gt).trim().toLowerCase();
      closeTag(stack, name);
      i = gt < 0 ? html.length : gt + 1;
      continue;
    }
    // 开始标签
    const parsed: TagParseResult = parseTag(html, lt);
    const node: HtmlNode = parsed.node;
    if (node.tag.length === 0) {
      i = parsed.end;
      continue;
    }
    // 隐式闭合：<li> / <p> 未闭合就遇到同标签，先关掉前一个（贴近 HTML5，提升真实页面结构还原）。
    if (IMPLICIT_CLOSE.indexOf(node.tag) >= 0) {
      const open: HtmlNode = stack[stack.length - 1];
      if (open.tag === node.tag) {
        stack.pop();
      }
    }
    const parent: HtmlNode = stack[stack.length - 1];
    node.parent = parent;
    parent.children.push(node);
    i = parsed.end;
    if (isVoid(node.tag)) {
      continue;
    }
    if (isRawText(node.tag)) {
      const closeToken: string = '</' + node.tag;
      if (!lowerReady) {
        lower = html.toLowerCase();
        lowerReady = true;
      }
      const closeStart: number = lower.indexOf(closeToken, i);
      const closeEnd: number = closeStart < 0 ? html.length : html.indexOf('>', closeStart) + 1;
      node.text = html.substring(i, closeStart < 0 ? html.length : closeStart);
      i = closeStart < 0 ? html.length : closeEnd;
      continue;
    }
    stack.push(node);
  }
  return root;
}

function appendText(parent: HtmlNode, value: string): void {
  if (value.length === 0) {
    return;
  }
  const text: HtmlNode = new HtmlNode('');
  text.text = value;
  text.parent = parent;
  parent.children.push(text);
}

function closeTag(stack: HtmlNode[], name: string): void {
  for (let i = stack.length - 1; i >= 1; i -= 1) {
    if (stack[i].tag === name) {
      stack.length = i;
      return;
    }
  }
}

/** 深度优先查找第一个指定标签的节点。 */
export function findFirst(node: HtmlNode, tag: string): HtmlNode | undefined {
  for (let i = 0; i < node.children.length; i += 1) {
    const child: HtmlNode = node.children[i];
    if (child.tag === tag) {
      return child;
    }
    const found: HtmlNode | undefined = findFirst(child, tag);
    if (found !== undefined) {
      return found;
    }
  }
  return undefined;
}

/** 提取节点的可见文本（不含 script/style 内容）。 */
export function textContent(node: HtmlNode): string {
  if (node.isText()) {
    return isDropTag(node.parent) ? '' : node.text;
  }
  if (isDropTag(node)) {
    return '';
  }
  let out: string = '';
  for (let i = 0; i < node.children.length; i += 1) {
    out += textContent(node.children[i]);
  }
  return out;
}

function isDropTag(node: HtmlNode | undefined): boolean {
  return node !== undefined && node.tag.length > 0 && DROP_WITH_CONTENT.indexOf(node.tag) >= 0;
}
