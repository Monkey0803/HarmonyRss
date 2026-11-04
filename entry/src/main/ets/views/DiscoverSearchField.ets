/** 发现页搜索输入：草稿由父页持有，输入只通过 V2 事件上报。 */
@ComponentV2
export struct DiscoverSearchField {
  @Param keyword: string = '';
  @Event onKeyword: (value: string) => void = (value: string) => {};

  build() {
    Row({ space: $r('app.float.space_s') }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_text_secondary')])
        .margin({ left: $r('app.float.space_m') })
        .flexShrink(0)
      TextInput({ text: this.keyword, placeholder: $r('app.string.discover_search_hint') })
        .type(InputType.Normal)
        .fontSize($r('app.float.font_size_body'))
        .layoutWeight(1)
        .height($r('app.float.search_field_height'))
        .backgroundColor($r('app.color.hm_page_transparent'))
        .padding({ left: 0, right: 0 })
        .enterKeyType(EnterKeyType.Search)
        .onChange((value: string) => {
          this.onKeyword(value);
        })
        .onSubmit(() => {
          this.getUIContext().getFocusController().clearFocus();
        })
      if (this.keyword.length > 0) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize($r('app.float.font_size_body'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .padding({
            left: $r('app.float.space_s'),
            right: $r('app.float.space_m'),
            top: $r('app.float.space_m'),
            bottom: $r('app.float.space_m')
          })
          .accessibilityText($r('app.string.discover_clear'))
          .onClick(() => {
            this.onKeyword('');
          })
      }
    }
    .width('100%')
    .height($r('app.float.search_field_height'))
    .backgroundColor($r('app.color.hm_value_chip_background'))
    .borderRadius($r('app.float.radius_search'))
    .alignItems(VerticalAlign.Center)
  }
}
