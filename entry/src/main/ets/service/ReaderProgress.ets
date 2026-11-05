/*
 * ReaderProgress.ets — 阅读进度：文档内位置读取与按比例恢复。
 *
 * 为什么要按比例：进度原来只存 window.scrollY（px），换字号 / 栏宽 / 主题后排版会重排、
 * 同一段文字对应的 px 会变，恢复位置就会漂。这里同时存一个 0–1 的比例
 * （y / (scrollHeight - innerHeight)），恢复时优先用比例换算，px 只作为老数据兜底。
 *
 * 位置主要靠文档内滚动监听实时上报（hrProgress.onScroll）；ArkTS 侧只保留低频轮询兜底，
 * 用于拿不到滚动事件的页面。
 */

/**
 * 把「滚动位置上报」注入页面：滚动时按 200ms 节流回传，正文进度不再靠 ArkTS 定时轮询。
 * 幂等：同一份文档重复注入只绑定一次监听。
 */
export function progressObserverScript(): string {
  return '(function(){if(window.__hrProgressBound){return;}window.__hrProgressBound=true;' +
    'var last=0;var send=function(){' +
    'var d=document.documentElement;var y=window.scrollY||(document.body?document.body.scrollTop:0)||0;' +
    'var h=d?d.scrollHeight:(document.body?document.body.scrollHeight:0);' +
    'var vh=window.innerHeight||0;' +
    'try{window.hrProgress.onScroll(y,h,vh);}catch(e){}};' +
    'window.addEventListener("scroll",function(){var now=Date.now();' +
    'if(now-last<200){return;}last=now;send();},{passive:true});' +
    'send();})()';
}

/** 由 y / scrollHeight / innerHeight 算出位置（口径与 parsePosition 一致）。 */
export function positionFromMetrics(y: number, h: number, vh: number): ReaderPosition {
  const safeY: number = Number.isFinite(y) && y > 0 ? y : 0;
  const span: number = Number.isFinite(h) && Number.isFinite(vh) ? h - vh : 0;
  const ratio: number = span > 0 ? Math.min(1, Math.max(0, safeY / span)) : 0;
  return new ReaderPosition(safeY, ratio);
}

/** 文档 → ArkTS 的滚动上报桥（javaScriptProxy 的 hrProgress.onScroll）。 */
export class ReaderProgressBridge {
  private readonly onReport: (y: number, h: number, vh: number) => void;

  constructor(onReport: (y: number, h: number, vh: number) => void) {
    this.onReport = onReport;
  }

  onScroll(y: number, h: number, vh: number): void {
    this.onReport(y, h, vh);
  }
}

/** 读取当前阅读位置：返回 "y|scrollHeight|innerHeight"。 */
export function readPositionScript(): string {
  return '(function(){var d=document.documentElement;' +
    'return (window.scrollY||0)+"|"+(d?d.scrollHeight:0)+"|"+(window.innerHeight||0);})()';
}

/** 文档内位置（px + 0–1 比例）。 */
export class ReaderPosition {
  readonly y: number;
  readonly ratio: number;

  constructor(y: number, ratio: number) {
    this.y = y;
    this.ratio = ratio;
  }
}

/**
 * 把 readPositionScript() 的返回值解析成 ReaderPosition。
 *
 * 注意：ArkWeb 的 runJavaScript 回调会把 JS 结果按 JSON 序列化，
 * 字符串返回值会带一层引号（如 "\"214.3|2400|1200\""），这里先去掉引号再解析。
 */
export function parsePosition(raw: string): ReaderPosition {
  const cleaned: string = (raw === undefined || raw === null)
    ? ''
    : raw.replace(/"/g, '').replace(/'/g, '').trim();
  const parts: string[] = cleaned.split('|');
  const y: number = Number(parts.length > 0 ? parts[0] : '');
  const h: number = Number(parts.length > 1 ? parts[1] : '');
  const vh: number = Number(parts.length > 2 ? parts[2] : '');
  const safeY: number = Number.isFinite(y) && y > 0 ? y : 0;
  const span: number = Number.isFinite(h) && Number.isFinite(vh) ? h - vh : 0;
  const ratio: number = span > 0 ? Math.min(1, Math.max(0, safeY / span)) : 0;
  return new ReaderPosition(safeY, ratio);
}

/**
 * 按比例（优先）或 px（兜底）落回位置的脚本。
 *
 * 不能只 scrollTo 一次：SPA 和懒加载图片会在 onPageEnd 之后继续拉长文档。
 * 每 200ms 校正一次，持续 5 秒，避免短暂稳定后提前结束。
 * 用户开始触摸、滚轮或键盘操作时立即停止校正，
 * 避免把主动滚动拉回旧位置。
 */
export function restorePositionScript(ratio: number, fallbackY: number): string {
  const r: string = (Number.isFinite(ratio) ? ratio : 0).toFixed(6);
  const y: string = Math.max(0, Math.round(Number.isFinite(fallbackY) ? fallbackY : 0)).toString();
  return '(function(){var r=' + r + ';var y=' + y + ';var n=0;' +
    'if(window.__hrRestoreCancel){window.__hrRestoreCancel();}' +
    'var done=function(){clearInterval(iv);window.removeEventListener("touchstart",done);' +
    'window.removeEventListener("wheel",done);window.removeEventListener("keydown",done);' +
    'window.__hrRestoreCancel=null;};window.__hrRestoreCancel=done;' +
    'window.addEventListener("touchstart",done,{passive:true});' +
    'window.addEventListener("wheel",done,{passive:true});window.addEventListener("keydown",done);' +
    'var pick=function(){var d=document.documentElement;var h=d?d.scrollHeight:0;' +
    'var vh=window.innerHeight||0;return {h:h,y:(r>0&&h>vh)?Math.round(r*(h-vh)):y};};' +
    'var iv=setInterval(function(){var p=pick();window.scrollTo(0,p.y);n++;' +
    'if(n>=25){done();}},200);})()';
}
