/*
 * ReaderProgress.ets — 阅读进度：文档内位置读取与按比例恢复。
 *
 * 为什么要按比例：进度原来只存 window.scrollY（px），换字号 / 栏宽 / 主题后排版会重排、
 * 同一段文字对应的 px 会变，恢复位置就会漂。这里同时存一个 0–1 的比例
 * （y / (scrollHeight - innerHeight)），恢复时优先用比例换算，px 只作为老数据兜底。
 *
 * 详情页通过 WebviewController 定期读取位置；ArkWeb 在部分页面没有暴露 JS 代理对象。
 */

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
 * 不能只 scrollTo 一次：SPA 在 onPageEnd 之后还会继续长内容，那时文档还太短，
 * 一次性滚动会被忽略 / 被后续渲染顶掉。所以每 200ms 校正一次，最多 3 秒；
 * 文档高度连续稳定后才提前结束。用户开始触摸、滚轮或键盘操作时立即停止校正，
 * 避免把主动滚动拉回旧位置。
 */
export function restorePositionScript(ratio: number, fallbackY: number): string {
  const r: string = (Number.isFinite(ratio) ? ratio : 0).toFixed(6);
  const y: string = Math.max(0, Math.round(Number.isFinite(fallbackY) ? fallbackY : 0)).toString();
  return '(function(){var r=' + r + ';var y=' + y + ';var n=0;var lastH=0;var stable=0;' +
    'if(window.__hrRestoreCancel){window.__hrRestoreCancel();}' +
    'var done=function(){clearInterval(iv);window.removeEventListener("touchstart",done);' +
    'window.removeEventListener("wheel",done);window.removeEventListener("keydown",done);' +
    'window.__hrRestoreCancel=null;};window.__hrRestoreCancel=done;' +
    'window.addEventListener("touchstart",done,{passive:true});' +
    'window.addEventListener("wheel",done,{passive:true});window.addEventListener("keydown",done);' +
    'var pick=function(){var d=document.documentElement;var h=d?d.scrollHeight:0;' +
    'var vh=window.innerHeight||0;return {h:h,y:(r>0&&h>vh)?Math.round(r*(h-vh)):y};};' +
    'var iv=setInterval(function(){var p=pick();window.scrollTo(0,p.y);n++;' +
    'stable=p.h===lastH?stable+1:0;lastH=p.h;' +
    'if(n>=15||(n>=4&&stable>=3&&Math.abs((window.scrollY||0)-p.y)<=4)){done();}},200);})()';
}
