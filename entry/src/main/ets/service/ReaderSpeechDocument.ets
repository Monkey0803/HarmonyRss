/* Reader 文档的朗读段落采集、跟读标记与手动滚动通知。 */

export class SpeechSegment {
  readonly id: number;
  readonly text: string;

  constructor(id: number, text: string) {
    this.id = id;
    this.text = text;
  }
}

interface SpeechSegmentRaw {
  id: number;
  text: string;
}

/** ArkWeb 可能把 JS 返回的 JSON 字符串再序列化一层。 */
export function parseSpeechSegments(raw: string): SpeechSegment[] {
  try {
    let value: Object = JSON.parse(raw) as Object;
    if (typeof value === 'string') {
      value = JSON.parse(value as string) as Object;
    }
    if (!Array.isArray(value)) {
      return [];
    }
    const result: SpeechSegment[] = [];
    const rows: SpeechSegmentRaw[] = value as SpeechSegmentRaw[];
    for (let i = 0; i < rows.length; i++) {
      const row: SpeechSegmentRaw = rows[i];
      if (typeof row.id === 'number' && Number.isInteger(row.id) && row.id >= 0 &&
        typeof row.text === 'string' && row.text.trim().length > 0) {
        result.push(new SpeechSegment(row.id, row.text.trim()));
      }
    }
    return result;
  } catch (_) {
    return [];
  }
}

/** 只取 Reader 的正文块；子块已被选中时不再重复朗读父块。 */
export function collectSpeechSegmentsScript(): string {
  return '(function(){var root=document.querySelector("article.reader");if(!root){return "[]";}' +
    'var sel="h1,h2,h3,h4,h5,h6,p,li,blockquote,pre";var nodes=root.querySelectorAll(sel);var out=[];' +
    'for(var i=0;i<nodes.length;i++){var n=nodes[i];if(n.querySelector(sel)){continue;}' +
    'var t=(n.textContent||"").replace(/\\s+/g," ").trim();if(!t){continue;}' +
    'var id=out.length;n.setAttribute("data-hr-speech",String(id));out.push({id:id,text:t});}' +
    'if(!out.length){var all=(root.textContent||"").replace(/\\s+/g," ").trim();' +
    'if(all){root.setAttribute("data-hr-speech","0");out.push({id:0,text:all});}}' +
    'return JSON.stringify(out);})()';
}

/** 一次只标当前段落；跟随关闭时只更新高亮，不移动用户正在看的位置。 */
export function markSpeechSegmentScript(id: number, follow: boolean): string {
  const safeId: number = Math.max(0, Math.round(id));
  return '(function(){var d=document;var style=d.getElementById("hr-speech-style");' +
    'if(!style){style=d.createElement("style");style.id="hr-speech-style";' +
    'style.textContent=".hr-speech-current{background:rgba(255,191,0,.18);border-radius:4px}";' +
    '(d.head||d.documentElement).appendChild(style);}' +
    'var old=d.querySelectorAll(".hr-speech-current");' +
    'for(var i=0;i<old.length;i++){old[i].classList.remove("hr-speech-current");}' +
    'var matches=d.querySelectorAll("article.reader [data-hr-speech]");var n=null;' +
    'for(var j=0;j<matches.length;j++){if(matches[j].getAttribute("data-hr-speech")==="' +
    safeId.toString() + '"){n=matches[j];break;}}' +
    'if(!n){return false;}n.classList.add("hr-speech-current");' +
    (follow ? 'n.scrollIntoView({block:"center",behavior:"smooth"});' : '') +
    'return true;})()';
}

export function clearSpeechSegmentScript(): string {
  return '(function(){var nodes=document.querySelectorAll(".hr-speech-current");' +
    'for(var i=0;i<nodes.length;i++){nodes[i].classList.remove("hr-speech-current");}})()';
}

/** 用户触摸拖动、鼠标滚轮或键盘滚动时通知 ArkTS 暂停自动跟随。 */
export function speechManualScrollScript(): string {
  return '(function(){if(window.__hrSpeechManualBound){return;}window.__hrSpeechManualBound=true;' +
    'var notify=function(){try{window.hrSpeechScroll.onManualScroll();}catch(e){}};' +
    'window.addEventListener("touchmove",notify,{passive:true});' +
    'window.addEventListener("wheel",notify,{passive:true});' +
    'window.addEventListener("keydown",function(e){' +
    'if(["ArrowDown","ArrowUp","PageDown","PageUp","Home","End"," "].indexOf(e.key)>=0){notify();}});})()';
}

export class ReaderSpeechScrollBridge {
  private readonly onScroll: () => void;

  constructor(onScroll: () => void) {
    this.onScroll = onScroll;
  }

  onManualScroll(): void {
    this.onScroll();
  }
}
