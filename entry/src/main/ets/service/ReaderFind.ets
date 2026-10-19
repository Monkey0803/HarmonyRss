/*
 * ReaderFind.ets — 正文内查找（注入文档脚本）。
 *
 * Reader 文档是我们自己生成的，网页原文模式则靠同样的一套注入；两种模式都用
 * 「按文本节点包裹 <mark>」的方式高亮，配合 scrollIntoView 定位。
 * 注入失败（站点 CSP / 文档未就绪）只表现为「找不到」，不影响阅读。
 *
 * 约定：查询串一律做 HTML 转义后再拼进脚本；计数与跳转都按 window.__hrFind 暴露的方法走。
 */

/** 高亮与当前命中项的样式（注入到文档 <head>）。 */
const FIND_STYLE_ID: string = 'hr-find-style';
const FIND_CSS: string =
  '.hr-find{background:#FFD54F;color:#1f1f1f;border-radius:2px;}' +
  '.hr-find-current{background:#FF9800;color:#1f1f1f;}';

/** HTML 转义，避免把用户输入当成标签拼进脚本字符串。 */
function escapeForScript(text: string): string {
  return text
    .replace(/\\/g, '\\\\')
    .replace(/'/g, '\\\'')
    .replace(/"/g, '\\"')
    .replace(/\n/g, '\\n')
    .replace(/</g, '\\u003c')
    .replace(/>/g, '\\u003e');
}

/** 注入样式 + window.__hrFind 工具方法（幂等）。 */
export function findSupportScript(): string {
  const css: string = escapeForScript(FIND_CSS);
  const id: string = escapeForScript(FIND_STYLE_ID);
  return '(function(){' +
    'var d=document;' +
    'var s=d.getElementById("' + id + '");' +
    'if(!s){s=d.createElement("style");s.id="' + id + '";(d.head||d.documentElement).appendChild(s);}' +
    's.textContent=\'' + css + '\';' +
    'if(window.__hrFind){return;}' +
    'window.__hrFind={' +
    // 收集可搜索的文本节点：跳过脚本/样式/已有的高亮标记，保证可重复调用
    'collect:function(){' +
    'var out=[];var walker=d.createTreeWalker(d.body,NodeFilter.SHOW_TEXT,{acceptNode:function(n){' +
    'var p=n.parentNode;if(!p){return NodeFilter.FILTER_REJECT;}' +
    'var t=p.nodeName?p.nodeName.toLowerCase():"";' +
    'if(t==="script"||t==="style"||t==="noscript"||t==="mark"){return NodeFilter.FILTER_REJECT;}' +
    'return n.nodeValue&&n.nodeValue.trim().length>0?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_REJECT;}});' +
    'while(walker.nextNode()){out.push(walker.currentNode);}return out;},' +
    // 清除上一次的高亮：把 <mark class="hr-find"> 还原成纯文本节点
    'clear:function(){' +
    'var marks=d.querySelectorAll("mark.hr-find");' +
    'for(var i=0;i<marks.length;i++){var m=marks[i];var parent=m.parentNode;' +
    'if(parent){parent.replaceChild(d.createTextNode(m.textContent||""),m);parent.normalize();}}' +
    'return true;},' +
    // 执行查找：先清后包，返回命中数
    'run:function(query){' +
    'window.__hrFind.clear();if(!query){return 0;}' +
    'var lower=query.toLowerCase();var count=0;var nodes=window.__hrFind.collect();' +
    'for(var i=0;i<nodes.length;i++){var node=nodes[i];var text=node.nodeValue||"";' +
    'var from=0;var idx=text.toLowerCase().indexOf(lower,from);if(idx<0){continue;}' +
    'var frag=d.createDocumentFragment();' +
    'while(idx>=0){' +
    'if(idx>from){frag.appendChild(d.createTextNode(text.substring(from,idx)));}' +
    'var mark=d.createElement("mark");mark.className="hr-find";' +
    'mark.textContent=text.substr(idx,query.length);frag.appendChild(mark);count++;' +
    'from=idx+query.length;idx=text.toLowerCase().indexOf(lower,from);}' +
    'if(from<text.length){frag.appendChild(d.createTextNode(text.substring(from)));}' +
    'if(node.parentNode){node.parentNode.replaceChild(frag,node);}}' +
    'return count;},' +
    // 定位到第 n 个命中项（高亮当前项）
    'goto:function(index){' +
    'var marks=d.querySelectorAll("mark.hr-find");' +
    'for(var i=0;i<marks.length;i++){marks[i].className="hr-find";}' +
    'if(index<0||index>=marks.length){return 0;}' +
    'var cur=marks[index];cur.className="hr-find hr-find-current";' +
    'try{cur.scrollIntoView({block:"center"});}catch(e){cur.scrollIntoView();}' +
    'return marks.length;}};' +
    '})()';
}

/** 执行查找，返回命中数（数字，ArkWeb 回调里不会带引号）。 */
export function runFindScript(query: string): string {
  return 'window.__hrFind?window.__hrFind.run(\'' + escapeForScript(query) + '\'):0';
}

/** 跳到第 index 个命中项。 */
export function gotoFindScript(index: number): string {
  const safe: number = Math.max(0, Math.round(index));
  return 'window.__hrFind?window.__hrFind.goto(' + safe + '):0';
}

/** 清空高亮。 */
export function clearFindScript(): string {
  return 'window.__hrFind?window.__hrFind.clear():true';
}

/** 读取当前命中数（清理之后用于确认）。 */
export function countFindScript(): string {
  return 'document.querySelectorAll("mark.hr-find").length';
}
