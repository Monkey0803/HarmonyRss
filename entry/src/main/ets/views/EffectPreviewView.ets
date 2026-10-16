/*
 * EffectPreviewView.ets — 光影效果预览（NavDestination 内容，纯展示）。
 *
 * 两种 UI Design Kit 光影效果：
 *   1) 点光源（hdsEffect.pointLight）—— 位置固定在组件中心、不随位移变化，因此这一页**不使用滚动容器**；
 *      视效全部来自 HomeViewModel，这里只读状态、上报触摸事件。
 *   2) 双边流光（HdsVisualComponent + HdsSceneType.DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK）——
 *      系统材质的两条边缘流光沿组件周界流动，自带背景蒙层，用于胶囊 / 卡片的高亮态。
 *
 * 本页无状态、单处使用，按 @performance/avoid-overusing-custom-component-check 的建议用全局 @Builder
 * 实现。流光场景控制器提到模块级常量：@Builder 每次渲染都会重新执行函数体，若在函数内 new 控制器，
 * 每次渲染都会重建流光场景、动画从头开始。
 */

import { HdsSceneController, HdsSceneType, HdsVisualComponent } from '@kit.UIDesignKit';
import { homeViewModel } from '../viewmodel/HomeViewModel';

/** 流光配色（系统材质上的高亮色，不随深浅色主题变化，故用色值常量集中定义）。 */
const FLOW_FIRST_COLOR: string = '#0A59F7';
const FLOW_SECOND_COLOR: string = '#7CC7FF';
const FLOW_MASK_TOP: string = '#121318';
const FLOW_MASK_BOTTOM: string = '#232838';

/**
 * 流光场景控制器：两条边分别从 0 流向 0.5 / -0.5（正负表示绕行方向），形成对开流动。
 * 模块级单例，保证跨渲染复用同一个场景。
 */
const flowController: HdsSceneController = new HdsSceneController().setSceneParams({
  backgroundMaskColors: [FLOW_MASK_TOP, FLOW_MASK_BOTTOM],
  firstEdgeFlowLight: {
    startPos: 0,
    endPos: 0.5,
    color: FLOW_FIRST_COLOR
  },
  secondEdgeFlowLight: {
    startPos: 0,
    endPos: -0.5,
    color: FLOW_SECOND_COLOR
  }
});

/** 受光体小卡片。 */
@Builder
function effectLightChip(label: ResourceStr) {
  Text(label)
    .fontSize($r('app.float.font_size_body'))
    .fontColor($r('app.color.hm_text_primary'))
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
}

/** 双边流光卡片：视效组件铺满卡片做底，文字浮在其上。 */
@Builder
function effectFlowLightCard() {
  Stack() {
    HdsVisualComponent()
      .scene(HdsSceneType.DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK, flowController)
      .width('100%')
      .height('100%')

    Column({ space: $r('app.float.space_xs') }) {
      Text($r('app.string.effect_flow_title'))
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_on_brand'))
        .fontWeight(FontWeight.Medium)
      Text($r('app.string.effect_flow_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_on_brand'))
    }
    .padding($r('app.float.space_l'))
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
  .width('100%')
  .height($r('app.float.flow_light_height'))
  .borderRadius($r('app.float.radius_card'))
  .clip(true)
}

@Builder
export function EffectPreviewView() {
  Column({ space: $r('app.float.space_l') }) {
    // 演示台：深色底，点光源效果更明显
    Column({ space: $r('app.float.space_l') }) {
      // 受光体：边缘 + 内容被照亮
      Column({ space: $r('app.float.space_s') }) {
        effectLightChip($r('app.string.effect_target'))
        effectLightChip($r('app.string.effect_target'))
      }
      .padding($r('app.float.space_l'))
      .borderRadius($r('app.float.radius_card'))
      .visualEffect(homeViewModel.illuminatedEffect())

      // 光源：按下点亮，同时自身边缘也受光
      Button($r('app.string.effect_source'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .fontColor($r('app.color.hm_on_brand'))
        .backgroundColor($r('app.color.hm_brand'))
        .visualEffect(homeViewModel.sourceEffect())
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            homeViewModel.press();
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            homeViewModel.release();
          }
        })
    }
    .padding($r('app.float.space_2xl'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.hm_effect_surface'))

    Text($r('app.string.effect_hint'))
      .fontSize($r('app.float.font_size_caption'))
      .fontColor($r('app.color.hm_text_secondary'))
      .textAlign(TextAlign.Center)

    effectFlowLightCard()
  }
  .width('100%')
  .height('100%')
  .padding($r('app.float.space_2xl'))
  .justifyContent(FlexAlign.Center)
  .alignItems(HorizontalAlign.Center)
  .backgroundColor($r('app.color.hm_page_transparent'))
}
