/*
 * FilterCapsule.ets — 通用筛选胶囊（「全部 / 未读 / 收藏 / 稍后读 / 归档」这种分段筛选）。
 *
 * 一处实现、两处复用：
 *   - 阅读页：挂在 HdsNavigation 标题栏的 bottomBuilder 上（onTitleBar = true），
 *     用组件级 systemMaterial 拿到 HDS 沉浸光感；材质不可用时「背板模糊 + 半透明色」兜底成玻璃面。
 *     沉浸光感是区域级能力：只有 Navigation/NavDestination 标题栏与横向 Tabs 的 TabBar 里
 *     组件才真正吃到系统材质，放内容区只会打 "Material inactive: out of scope"。
 *   - 搜索页：放在内容区的卡片里（onTitleBar = false），材质不生效，改用平底色胶囊。
 *
 * 为什么不用 HDS 的 TabSegmentButtonV2：它按「按钮个数平均分配可用宽度」且不支持通用属性，
 * 多语言下德 / 法 / 西文案会被截成「Un…」「Un…」，无法完整显示。这里自绘：每项按文字宽度排布，
 * 空间富余时首尾贴边均分缝隙，超出时整条横向可滑动、不截断文字。
 *
 * 为什么是 @ComponentV2 而不是全局 @Builder：调用方各有自己的 ViewModel（阅读页 FeedViewModel、
 * 搜索页 SearchViewModel），选中值必须由 @Param 传进来；多参 @Builder 不随状态刷新
 * （选中态会停在旧值），V2 的 @Param 才能真正跟随 @Trace 源更新。
 */

import { appSettings } from '../model/AppSettings';
import { MaterialController } from '../service/MaterialController';

@ComponentV2
export struct FilterCapsule {
  /** 选项值，数组顺序即展示顺序。 */
  @Param options: string[] = [];
  /** 与 options 一一对应的文案。 */
  @Param labels: ResourceStr[] = [];
  /** 当前选中值。 */
  @Param active: string = '';
  /** true = 用在标题栏（吃系统材质）；false = 用在内容区（平底色）。 */
  @Param onTitleBar: boolean = false;
  /** 选中某项。 */
  @Event onSelect: (value: string) => void = () => {
  };

  /** 按文案宽度排布，整条横向可滚动。 */
  @Builder
  Chips() {
    Scroll() {
      Row({ space: $r('app.float.space_xxs') }) {
        ForEach(this.options, (value: string, index: number) => {
          Text(this.labels[index])
            .fontSize($r('app.float.font_size_caption'))
            .fontWeight(this.active === value ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(this.active === value
              ? $r('app.color.hm_brand')
              : $r('app.color.hm_text_primary'))
            .maxLines(1)
            .height('100%')
            .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
            .borderRadius($r('app.float.radius_chip'))
            .backgroundColor(this.active === value
              ? $r('app.color.hm_card_background')
              : $r('app.color.hm_page_transparent'))
            .onClick(() => {
              this.onSelect(value);
            })
        }, (value: string) => value)
      }
      .height('100%')
      // 文案总宽小于胶囊时撑满胶囊并均分剩余空隙 —— 否则内容靠左，首尾两项到胶囊左右边的
      // 间距不一致（第一项贴着左边、最后一项与右边空出一大截）。
      // 文案超出（长语言）时仍按内容自然宽度排布，整条可横向滚动，不截断文字。
      .constraintSize({ minWidth: '100%' })
      .justifyContent(FlexAlign.SpaceBetween)
      .padding({ left: $r('app.float.space_xs'), right: $r('app.float.space_xs') })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .align(Alignment.Start)
  }

  /** 标题栏 + 沉浸光感：材质由系统渲染，底色必须留透明。 */
  @Builder
  CapsuleWithMaterial() {
    Row() {
      this.Chips()
    }
    .width('100%')
    .height($r('app.float.value_chip_height'))
    .borderRadius($r('app.float.radius_chip'))
    .clip(true)
    .systemMaterial(MaterialController.titleMaterial(appSettings.immersiveOn))
    .alignItems(VerticalAlign.Center)
  }

  /** 标题栏但无光感能力：半透明底 + 背景模糊兜底成玻璃面。 */
  @Builder
  CapsuleOnGlass() {
    Row() {
      this.Chips()
    }
    .width('100%')
    .height($r('app.float.value_chip_height'))
    .borderRadius($r('app.float.radius_chip'))
    .clip(true)
    .backgroundColor($r('app.color.hm_glass_scrim'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .alignItems(VerticalAlign.Center)
  }

  /** 内容区：材质不生效，用平底色胶囊（白色选中片在其上仍然有层级）。 */
  @Builder
  CapsuleFlat() {
    Row() {
      this.Chips()
    }
    .width('100%')
    .height($r('app.float.value_chip_height'))
    .borderRadius($r('app.float.radius_chip'))
    .clip(true)
    .backgroundColor($r('app.color.hm_value_chip_background'))
    .alignItems(VerticalAlign.Center)
  }

  build() {
    if (!this.onTitleBar) {
      this.CapsuleFlat()
    } else if (MaterialController.materialRenders(appSettings.immersiveOn)) {
      this.CapsuleWithMaterial()
    } else {
      this.CapsuleOnGlass()
    }
  }
}
