/*
 * ReaderProgress.ets — 阅读进度：文档内位置读取、按比例恢复、实时回报。
 *
 * 为什么要按比例：进度原来只存 window.scrollY（px），换字号 / 栏宽 / 主题后排版会重排、
 * 同一段文字对应的 px 会变，恢复位置就会漂。这里同时存一个 0–1 的比例
 * （y / (scrollHeight - innerHeight)），恢复时优先用比例换算，px 只作为老数据兜底。
 *
 * 实时回报走 javaScriptProxy：文档里注入一个节流 200ms 的 scroll 监听，回调到
 * ReaderProgressBridge.onProgress(ratio)，UI 据此画进度条。
 * 注入失败（站点 CSP / 代理未注册）只影响进度条刷新，不影响阅读。
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
 * 一次性滚动会被忽略 / 被后续渲染顶掉。所以每 250ms 校正一次，最多 3 秒，
 * 或者一旦真的落到目标位置就停。比例模式下每次都按当前 scrollHeight 重算目标，
 * 这样「文档长高了」也能落到正确的一段。
 */
export function restorePositionScript(ratio: number, fallbackY: number): string {
  const r: string = (Number.isFinite(ratio) ? ratio : 0).toFixed(6);
  const y: string = Math.max(0, Math.round(Number.isFinite(fallbackY) ? fallbackY : 0)).toString();
  return '(function(){var r=' + r + ';var y=' + y + ';var n=0;' +
    'var pick=function(){var d=document.documentElement;var h=d?d.scrollHeight:0;' +
    'var vh=window.innerHeight||0;return (r>0&&h>vh)?Math.round(r*(h-vh)):y;};' +
    'var iv=setInterval(function(){var t=pick();window.scrollTo(0,t);n++;' +
    'if(n>12||Math.abs((window.scrollY||0)-t)<=4){clearInterval(iv);}},250);})()';
}

/**
 * 注入滚动监听（节流 200ms），把比例回报给 ArkTS（javaScriptProxy 名为 window.hrProgress）。
 * 幂等：重复注入只保留一个监听。
 */
export function progressListenerScript(): string {
  return '(function(){if(window.__hrProgressBound){return;}window.__hrProgressBound=true;' +
    'var pending=0;var report=function(){var d=document.documentElement;' +
    'var h=d?d.scrollHeight:0;var vh=window.innerHeight||0;var y=window.scrollY||0;' +
    'var r=(h>vh)?Math.min(1,Math.max(0,y/(h-vh))):0;' +
    'try{if(window.hrProgress){window.hrProgress.onProgress(r);}}catch(e){}};' +
    'window.addEventListener("scroll",function(){if(pending){return;}' +
    'pending=setTimeout(function(){pending=0;report();},200);},{passive:true});' +
    'report();})()';
}

/**
 * 注入到 Web 的 ArkTS 对象：文档内脚本通过 window.hrProgress.* 回调。
 * 方法必须是同步签名（javaScriptProxy 的约定）。
 */
export class ReaderProgressBridge {
  private readonly onRatio: (ratio: number) => void;

  constructor(onRatio: (ratio: number) => void) {
    this.onRatio = onRatio;
  }

  /** 由文档内脚本调用；参数是 0–1 的阅读进度。 */
  onProgress(ratio: number): void {
    this.onRatio(ratio);
  }
}
