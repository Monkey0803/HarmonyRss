/*
 * ResponsiveContent.ets — 内容收窄容器（宽面板不再拉满整行）。
 *
 * 用 GridRow/GridCol 按断点给内容加左右留白：
 *   < 600vp  12/12（满宽）
 *   600–840  10/12 + 1 列偏移
 *   ≥ 840    8/12 + 2 列偏移
 *
 * 断点参考系用 ComponentSize（容器宽度），不是 skill 模板里的 WindowSize：
 * 本 App 的内容活在 HdsNavigation 分栏的左右栏里（左栏 360–560vp、右栏 240–640vp），
 * 按窗口宽度取列会把左栏再压成 8/12；按容器宽度取列，窄栏自然保持满宽，宽栏才收窄。
 */

import { BreakpointConstants } from '../common/constants/BreakpointConstants';

@ComponentV2
export struct ResponsiveContent {
  /** @BuilderParam 的默认值必须是 @Builder 方法（不能是箭头函数）。 */
  @Builder
  emptyContent() {
  }

  @BuilderParam content: () => void = this.emptyContent;

  build() {
    GridRow({
      columns: 12,
      gutter: 0,
      breakpoints: {
        value: BreakpointConstants.WINDOW_BREAKPOINTS,
        reference: BreakpointsReference.ComponentSize
      }
    }) {
      GridCol({
        span: { xs: 12, sm: 12, md: 10, lg: 8 },
        offset: { xs: 0, sm: 0, md: 1, lg: 2 }
      }) {
        this.content()
      }
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
