/** 由系统放在卡片出框区域内的短动效。 */
@Entry
@ComponentV2
struct RssLiveCardPage {
  @Local lifted: boolean = false;

  build() {
    Stack() {
      Column() {
        Text('✦')
          .fontSize(40)
          .fontColor($r('app.color.hm_brand'))
        Text($r('app.string.widget_title'))
          .fontSize($r('app.float.font_size_section'))
          .fontColor($r('app.color.hm_text_primary'))
      }
      .width('70%')
      .height('65%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.hm_card_background'))
      .borderRadius($r('app.float.radius_card'))
      .scale({ x: this.lifted ? 1.14 : 0.85, y: this.lifted ? 1.14 : 0.85 })
      .translate({ y: this.lifted ? -32 : 20 })
      .opacity(this.lifted ? 1 : 0.4)
    }
    .width('100%')
    .height('100%')
    .onAppear(() => {
      animateTo({ duration: 900, curve: Curve.EaseOut }, () => {
        this.lifted = true;
      });
    })
  }
}
