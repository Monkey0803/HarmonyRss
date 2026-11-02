/**
 * ChoiceField.ets — 「当前值 + 实心倒三角」取值胶囊。
 *
 * 设置页选项行、订阅设置、存储页三处原本各写了一遍同样的胶囊（高度 / 内边距 / 底色 / 圆角
 * 完全一致），这里收成一处，避免改样式时漏改其中一两个页面。
 *
 * 为什么是 @ComponentV2 而不是全局 @Builder：
 * 自定义构建函数按值传参时**不随参数变化刷新**（选完新值后行上仍显示旧文案），
 * 这里必须用 @Param 走 V2 的单向同步，才能跟着 appSettings 的 @Trace 字段更新。
 *
 * 长文案（德语「Systemeinstellung folgen」等）限宽并省略，避免把左侧标题挤没。
 */

@ComponentV2
export struct ChoiceValueChip {
  /** 当前值的展示文案。 */
  @Param label: ResourceStr = '';

  build() {
    Row({ space: $r('app.float.space_xs') }) {
      Text(this.label)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
        .fontSize($r('app.float.icon_size_tiny'))
        .fontColor([$r('app.color.hm_text_primary')])
        .flexShrink(0)
    }
    .constraintSize({ maxWidth: '58%' })
    .flexShrink(0)
    .height($r('app.float.value_chip_height'))
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    .backgroundColor($r('app.color.hm_value_chip_background'))
    .borderRadius($r('app.float.radius_chip'))
  }
}
