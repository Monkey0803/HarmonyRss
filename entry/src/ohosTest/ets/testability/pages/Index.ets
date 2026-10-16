@Entry
@ComponentV2
struct Index {
  @Local message: string = 'HarmonyRss test';

  build() {
    Row() {
      Column() {
        Text(this.message)
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
    }
    .height('100%')
  }
}
