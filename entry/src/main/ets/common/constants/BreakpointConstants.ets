/*
 * BreakpointConstants.ets — 窗口断点（逻辑条件串）。
 *
 * 断点值属于「逻辑条件」，不是视觉尺寸，所以放 common/constants；侧栏宽度等尺寸仍走 float.json。
 *
 * 三档模式（与 pages/Index 的外壳选择一一对应）：
 *   < 600vp     底部页签 + Stack（单栏）
 *   600–1000vp  底部页签 + Split（列表 | 详情）
 *   ≥ 1000vp    侧栏 + Split（侧栏 200 + 列表 360 + 详情）
 *
 * 侧栏阈值取 1000 而不是 840：本 App 在大屏上保留「列表 | 详情」分栏，
 * 三栏同时放得下（侧栏 200 + 列表 360 + 详情 ≥ 440）才不会把阅读区压得太窄。
 */
export class BreakpointConstants {
  /** ResponsiveContent 的列断点（与 GridRow breakpoints 的 xs/sm/md/lg 对应）。 */
  static readonly WINDOW_BREAKPOINTS: string[] = ['600vp', '840vp'];
  /** 列表 | 详情 分栏。 */
  static readonly SPLIT_MEDIA_QUERY: string = '(width>=600vp)';
  /** 侧边栏外壳（三栏）。 */
  static readonly RAIL_MEDIA_QUERY: string = '(width>=1000vp)';
}
