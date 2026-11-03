/*
 * SheetDetents.ets — 半模态三挡高度（官方「设置三个不同高度的挡位」的纯函数封装）。
 *
 * 拆成独立模块而不是写在 AppSheet 里：这里只有类型与纯计算，单测可以直接 import，
 * 不会把 @ComponentV2 / ArkUI 装饰器带进测试环境。
 *
 * 三挡规则：
 *   - 首挡：调用方给的面板初始高度（保持各面板迁移前的观感）；
 *   - 次挡：比首挡再大 / 小一档；
 *   - 紧凑挡：固定 320vp，配合内容区内部滚动。
 */

/** 三挡位（与 SheetOptions.detents 的三元组结构一致，可直接赋值）。 */
export type AppSheetDetents = [SheetSize | Length, SheetSize | Length, SheetSize | Length];

/** 紧凑挡高度（vp）：拖到最低时的面板高度，内容区内部滚动。 */
export const SHEET_COMPACT_DETENT: number = 320;

/** 「添加订阅 / 保存网页」面板的初始高度（vp，沿用迁移前的 height）。 */
export const SHEET_ADD_FEED_HEIGHT: number = 500;

/** 「保存到文件夹」面板的初始高度（vp，沿用迁移前的 height）。 */
export const SHEET_SAVE_FOLDER_HEIGHT: number = 360;

/**
 * 按初始挡生成三挡高度。
 *
 * 长内容（LARGE）先给全高、向下可收；中等内容（MEDIUM）可展开 / 收起；
 * 固定 vp 的短面板保持原高度，只向上扩展 —— 避免短面板首屏出现大片空白。
 */
export function sheetDetentsFor(initial: SheetSize | Length): AppSheetDetents {
  if (initial === SheetSize.LARGE) {
    return [SheetSize.LARGE, SheetSize.MEDIUM, SHEET_COMPACT_DETENT];
  }
  if (initial === SheetSize.MEDIUM) {
    return [SheetSize.MEDIUM, SheetSize.LARGE, SHEET_COMPACT_DETENT];
  }
  return [initial, SheetSize.MEDIUM, SheetSize.LARGE];
}
