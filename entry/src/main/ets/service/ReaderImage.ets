/*
 * ReaderImage.ets — 正文图片命中测试。
 *
 * ArkWeb 实测不会把合成点按派发成 DOM 事件（click / touch 都可能收不到），
 * 所以命中判定放在 ArkTS 一侧：把触摸点（组件内坐标，vp≈CSS px）传进文档，
 * 用 elementFromPoint 找到点击位置的元素，再向上找最近的 <img>，返回它的地址。
 * 拿到地址就打开大图；拿不到就当作普通点按（切换沉浸栏）。
 */

/** 命中测试脚本：参数是 Web 组件内的坐标（CSS px）。 */
export function imageAtPointScript(x: number, y: number): string {
  const px: string = Math.max(0, x).toFixed(1);
  const py: string = Math.max(0, y).toFixed(1);
  return '(function(){var el=document.elementFromPoint(' + px + ',' + py + ');' +
    'var img=(el&&el.closest)?el.closest("img"):null;' +
    'return img?(img.currentSrc||img.src||""):"";})()';
}
