/*
 * PrivacyVeil.ets — 防窥遮罩（纯展示）。
 *
 * 盖住除页签栏以外的内容，轻点任意位置把「继续查看」事件交给共享的 AntiPeep 控制器。
 *
 * 无状态、单处使用，因此按 @performance/avoid-overusing-custom-component-check 的建议
 * 用全局 @Builder 实现（省掉一层自定义组件的开销）。调用处写法不变：`PrivacyVeil()`。
 */

import { antiPeep } from '../service/AntiPeep';

@Builder
export function PrivacyVeil() {
  Column({ space: $r('app.float.space_l') }) {
    SymbolGlyph($r('sys.symbol.eye_slash'))
      .fontSize($r('app.float.hero_icon_size'))
      .fontColor([$r('app.color.hm_text_primary')])
    Text($r('app.string.veil_message'))
      .fontSize($r('app.float.font_size_body'))
      .fontColor($r('app.color.hm_text_primary'))
    Text($r('app.string.veil_dismiss'))
      .fontSize($r('app.float.font_size_section'))
      .fontColor($r('app.color.hm_text_secondary'))
  }
  .width('100%')
  .height('100%')
  .justifyContent(FlexAlign.Center)
  .backgroundColor($r('app.color.hm_veil_background'))
  .onClick(() => {
    antiPeep.acknowledge();
  })
}
