/*
 * ReaderToc.ets — 正文目录（标题采集 / 跳转）脚本。
 *
 * 只在阅读容器 `.reader` 内找标题（网页原文模式退回 body），避免把站点导航里的
 * 标题也当成目录项。采集时给每个保留的标题记下它在 NodeList 里的原始下标，
 * 跳转直接按这个下标取节点 —— 与「跳过空标题」的过滤逻辑无关。
 */

/** 目录项：层级 + 文本 + 在标题 NodeList 里的下标。 */
export class TocEntry {
  readonly level: number;
  readonly text: string;
  readonly index: number;

  constructor(level: number, text: string, index: number) {
    this.level = level;
    this.text = text;
    this.index = index;
  }
}

/** 采集标题，返回 JSON 数组字符串：[{level,text,index}]。 */
export function collectTocScript(): string {
  return '(function(){var root=document.querySelector(".reader")||document.body;' +
    'var hs=root.querySelectorAll("h1,h2,h3,h4");var out=[];' +
    'for(var i=0;i<hs.length;i++){var t=(hs[i].textContent||"").replace(/\\s+/g," ").trim();' +
    'if(t.length===0){continue;}' +
    'out.push({level:parseInt(hs[i].tagName.substring(1),10),text:t,index:i});}' +
    'return JSON.stringify(out);})()';
}

/** 跳到标题 NodeList 的第 index 个节点。 */
export function gotoHeadingScript(index: number): string {
  const i: string = Math.max(0, Math.round(index)).toString();
  return '(function(){var root=document.querySelector(".reader")||document.body;' +
    'var hs=root.querySelectorAll("h1,h2,h3,h4");var h=hs[' + i + '];' +
    'if(!h){return "0";}h.scrollIntoView({block:"start"});return "1";})()';
}
