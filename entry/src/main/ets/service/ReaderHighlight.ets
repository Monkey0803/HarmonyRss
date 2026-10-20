/*
 * ReaderHighlight.ets — 正文标注的文档内脚本（注入到 Reader 文档 / 网页原文）。
 *
 * 与 ReaderFind 同一套思路：按**文本节点**找到引文并包成 <mark>，定位靠 scrollIntoView。
 * 差别在这里的标记是「要留着」的：clear 只清「本次重放」产生的标记，标注本身不在文档里持久化，
 * 而是每次打开 / 引文变动后由 ArkTS 侧把标注列表传进来重放一次。
 *
 * 约定：window.__hrHl 暴露 apply / goto / clear / ratioOfSelection；点击标记回调到
 * window.__hrHlCb.onHlClick(id)（由 ArkTS 侧通过 javaScriptProxy 注入）。
 */

/** 注入到文档 <head> 的样式：四档配色 + 点击反馈。 */
const HL_STYLE_ID: string = 'hr-hl-style';
const HL_CSS: string =
  'mark.hr-hl{border-radius:2px;padding:0 .05em;cursor:pointer;}' +
  'mark.hr-hl-yellow{background:#FFE082;}' +
  'mark.hr-hl-green{background:#B7E8B7;}' +
  'mark.hr-hl-blue{background:#B3D9FF;}' +
  'mark.hr-hl-pink{background:#FFC7DC;}' +
  'mark.hr-hl-note{border-bottom:2px solid #FF9800;}' +
  '@media (prefers-color-scheme: dark){' +
  'mark.hr-hl{color:#1f1f1f;}' +
  'mark.hr-hl-yellow{background:#C9A227;}mark.hr-hl-green{background:#4C8C4C;}' +
  'mark.hr-hl-blue{background:#3E6E9E;}mark.hr-hl-pink{background:#B5566F;}}';

/** 转义：引文与备注都可能含引号 / 换行 / 尖括号，拼进脚本字符串前必须处理。 */
function escapeForScript(text: string): string {
  return text
    .replace(/\\/g, '\\\\')
    .replace(/'/g, '\\\'')
    .replace(/"/g, '\\"')
    .replace(/\n/g, '\\n')
    .replace(/</g, '\\u003c')
    .replace(/>/g, '\\u003e');
}

/**
 * 注入样式 + window.__hrHl 工具（幂等，可重复调用）。
 * 只依赖 DOM 原生能力，站点 CSP 拒绝执行时只是没有高亮，不影响阅读。
 */
export function highlightSupportScript(): string {
  const css: string = escapeForScript(HL_CSS);
  const id: string = escapeForScript(HL_STYLE_ID);
  return '(function(){' +
    'var d=document;' +
    'var s=d.getElementById("' + id + '");' +
    'if(!s){s=d.createElement("style");s.id="' + id + '";(d.head||d.documentElement).appendChild(s);}' +
    's.textContent=\'' + css + '\';' +
    'if(window.__hrHl){return;}' +
    'window.__hrHl={' +
    'items:[],' +
    // 收集文本节点：跳过脚本/样式与已有标记（避免把上一次重放的标记再包一层）
    'collect:function(){' +
    'var out=[];var walker=d.createTreeWalker(d.body,NodeFilter.SHOW_TEXT,{acceptNode:function(n){' +
    'var p=n.parentNode;if(!p){return NodeFilter.FILTER_REJECT;}' +
    'var t=p.nodeName?p.nodeName.toLowerCase():"";' +
    'if(t==="script"||t==="style"||t==="noscript"||t==="mark"){return NodeFilter.FILTER_REJECT;}' +
    'return n.nodeValue&&n.nodeValue.length>0?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_REJECT;}});' +
    'while(walker.nextNode()){out.push(walker.currentNode);}return out;},' +
    // 清掉本次重放产生的标记
    'clear:function(){' +
    'var marks=d.querySelectorAll("mark.hr-hl");' +
    'for(var i=0;i<marks.length;i++){var m=marks[i];var p=m.parentNode;' +
    'if(p){p.replaceChild(d.createTextNode(m.textContent||""),m);p.normalize();}}' +
    'return true;},' +
    // 把一条引文包成标记；命中返回 true
    'wrap:function(quote,hlId,color,hasNote){' +
    'if(!quote){return false;}' +
    'var nodes=window.__hrHl.collect();' +
    'for(var i=0;i<nodes.length;i++){var node=nodes[i];var text=node.nodeValue||"";' +
    'var idx=text.indexOf(quote);if(idx<0){continue;}' +
    'var frag=d.createDocumentFragment();' +
    'if(idx>0){frag.appendChild(d.createTextNode(text.substring(0,idx)));}' +
    'var mark=d.createElement("mark");' +
    'mark.className="hr-hl hr-hl-"+color+(hasNote?" hr-hl-note":"");' +
    'mark.setAttribute("data-hl",hlId);mark.textContent=quote;' +
    'mark.addEventListener("click",function(ev){' +
    'ev.stopPropagation();' +
    'if(window.__hrHlCb&&window.__hrHlCb.onHlClick){window.__hrHlCb.onHlClick(this.getAttribute("data-hl"));}' +
    '});' +
    'frag.appendChild(mark);' +
    'var rest=text.substring(idx+quote.length);' +
    'if(rest.length>0){frag.appendChild(d.createTextNode(rest));}' +
    'if(node.parentNode){node.parentNode.replaceChild(frag,node);}' +
    'return true;}' +
    'return false;},' +
    // 重放：先清后包，返回成功定位的条数
    'apply:function(items){' +
    'window.__hrHl.clear();window.__hrHl.items=items||[];var ok=0;' +
    'for(var i=0;i<window.__hrHl.items.length;i++){var it=window.__hrHl.items[i];' +
    'if(window.__hrHl.wrap(it.q,it.id,it.c,it.n?true:false)){ok++;}}' +
    'return ok;},' +
    // 跳到某条标注
    'goto:function(hlId){' +
    'var m=d.querySelector("mark.hr-hl[data-hl=\\""+hlId+"\\"]");' +
    'if(!m){return false;}' +
    'try{m.scrollIntoView({block:"center"});}catch(e){m.scrollIntoView();}' +
    'return true;},' +
    // 按比例跳（引文定位失败时的兜底）
    'gotoRatio:function(ratio){' +
    'var h=d.documentElement.scrollHeight-window.innerHeight;' +
    'if(h<=0){return false;}window.scrollTo(0,h*ratio);return true;},' +
    // 当前选区起点在文中的位置比例（新增标注时记下来当兜底锚点）
    'ratioOfSelection:function(){' +
    'var sel=window.getSelection();if(!sel||sel.rangeCount===0){return 0;}' +
    'var rect=sel.getRangeAt(0).getBoundingClientRect();' +
    'var top=rect.top+window.scrollY;var h=d.documentElement.scrollHeight;' +
    'return h>0?top/h:0;}' +
    '};' +
    '})()';
}

/** 把标注列表重放一次（引文 + id + 配色 + 是否有备注）。 */
export function applyHighlightsScript(items: HighlightItem[]): string {
  const parts: string[] = [];
  for (let i = 0; i < items.length; i += 1) {
    const it: HighlightItem = items[i];
    parts.push('{id:\'' + escapeForScript(it.id) + '\',q:\'' + escapeForScript(it.quote) +
      '\',c:\'' + escapeForScript(it.color) + '\',n:' + (it.hasNote ? '1' : '0') + '}');
  }
  return 'window.__hrHl?window.__hrHl.apply([' + parts.join(',') + ']):0';
}

/** 跳到某条标注；返回是否找到。 */
export function gotoHighlightScript(id: string): string {
  return 'window.__hrHl?window.__hrHl.goto(\'' + escapeForScript(id) + '\'):false';
}

/** 按比例跳（兜底）。 */
export function gotoRatioScript(ratio: number): string {
  const safe: number = Math.min(1, Math.max(0, ratio));
  return 'window.__hrHl?window.__hrHl.gotoRatio(' + safe + '):false';
}

/** 读当前选区的位置比例（新增标注时作为兜底锚点）。 */
export function selectionRatioScript(): string {
  return 'window.__hrHl?window.__hrHl.ratioOfSelection():0';
}

/**
 * 文档内点标注 → ArkTS 的回调桥（由 javaScriptProxy 注册成 window.__hrHlCb）。
 * 只暴露一个方法名，方法列表见组件侧的 javaScriptProxy methodList。
 */
export class ReaderHighlightBridge {
  private readonly onClick: (id: string) => void;

  constructor(onClick: (id: string) => void) {
    this.onClick = onClick;
  }

  /** 由文档内脚本调用；参数是标注 id。 */
  onHlClick(id: string): void {
    this.onClick(id);
  }
}

/** 注入脚本用的一行标注数据。 */
export class HighlightItem {
  readonly id: string;
  readonly quote: string;
  readonly color: string;
  readonly hasNote: boolean;

  constructor(id: string, quote: string, color: string, hasNote: boolean) {
    this.id = id;
    this.quote = quote;
    this.color = color;
    this.hasNote = hasNote;
  }
}
