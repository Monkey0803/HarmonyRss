/*
 * RssWidgetCard.ets — 服务卡片（桌面卡片）的 UI。
 *
 * 状态管理 V2：卡片入口组件用 @Entry @ComponentV2，不再创建 / 传入 LocalStorage。
 * 卡片提供方（RssWidgetAbility）通过 updateForm 推送数据，V2 下**按变量名匹配**字段
 * （unread / t1 / t2 / t3 / dimension 与推送 key 同名，见 common/constants/WidgetConstants）。
 *
 * 尺寸适配：form_config.json 声明支持 2*2 与 2*4。两种尺寸信息量不同 —— 2*2 只放未读数 + 1 条
 * 标题，2*4 放最多 3 条；尺寸由提供方从 want 参数读出后随数据下发（dimension 字段）。
 * 卡片只做展示，点击卡片拉起应用。
 */

import { WidgetConstants } from '../common/constants/WidgetConstants';

@Entry
@ComponentV2
struct RssWidgetCard {
  @Local unread: number = 0;
  @Local t1: string = '';
  @Local t2: string = '';
  @Local t3: string = '';
  /** 卡片尺寸语义值：small（2*2）/ large（2*4）。由提供方下发，默认按大卡片渲染。 */
  @Local dimension: string = WidgetConstants.DIMENSION_LARGE;

  private isSmall(): boolean {
    return this.dimension === WidgetConstants.DIMENSION_SMALL;
  }

  @Builder
  TitleLine(text: string) {
    Row({ space: $r('app.float.space_s') }) {
      Divider()
        .vertical(true)
        // Divider.strokeWidth 只接受 number | string，不能用资源引用。
        .strokeWidth(2)
        .color($r('app.color.hm_brand'))
        .height($r('app.float.space_m'))
      Text(text)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
  }

  /** 无数据时的占位（两种尺寸共用）。 */
  @Builder
  EmptyHint() {
    Text($r('app.string.widget_empty'))
      .fontSize($r('app.float.font_size_caption'))
      .fontColor($r('app.color.hm_text_secondary'))
      .maxLines(2)
  }

  @Builder
  Header() {
    Row() {
      Text($r('app.string.widget_title'))
        .fontSize($r('app.float.font_size_section'))
        .fontColor($r('app.color.hm_text_primary'))
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text($r('app.string.home_unread_count', this.unread))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_brand'))
    }
    .width('100%')
  }

  build() {
    Column({ space: $r('app.float.space_s') }) {
      this.Header()

      if (this.t1.length > 0) {
        this.TitleLine(this.t1)
      } else {
        this.EmptyHint()
      }

      // 2*2 只放一条标题；2*4 再补两条，避免小卡片内容溢出。
      if (!this.isSmall()) {
        if (this.t2.length > 0) {
          this.TitleLine(this.t2)
        }
        if (this.t3.length > 0) {
          this.TitleLine(this.t3)
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .onClick(() => {
      // 点击卡片拉起应用主页面。
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: {}
      });
    })
  }
}
