import { WidgetConstants } from '../common/constants/WidgetConstants';
import { DeepLinkParams } from '../service/DeepLink';

/** 独立 2×2 互动卡片；提供方与普通卡片共用只读数据。 */
@Entry
@ComponentV2
struct RssInteractiveCard {
  @Local unread: number = 0;
  @Local t1: string = '';
  @Local i1: string = '';
  /** 主题色 accent（提供方按当前深浅色算好下发）；空串回退资源默认色。 */
  @Local themeAccent: string = '';

  /** 卡片品牌色：主题色优先，未收到数据时用资源默认值。 */
  private brand(): ResourceColor {
    return this.themeAccent.length > 0 ? this.themeAccent : $r('app.color.hm_brand');
  }

  private animate(): void {
    const params: Record<string, Object> = {};
    params[WidgetConstants.PARAM_EVENT] = WidgetConstants.EVENT_ANIMATE;
    postCardAction(this, { action: 'message', params: params });
  }

  private openArticle(): void {
    const params: Record<string, Object> = {};
    if (this.i1.length > 0) {
      params[DeepLinkParams.ARTICLE_ID] = this.i1;
    }
    postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: params });
  }

  build() {
    Column({ space: $r('app.float.space_s') }) {
      Row() {
        Text($r('app.string.widget_title'))
          .fontSize($r('app.float.font_size_section'))
          .fontColor($r('app.color.hm_text_primary'))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        Text('✦')
          .fontSize($r('app.float.font_size_section'))
          .fontColor(this.brand())
          .accessibilityText($r('app.string.widget_animate'))
          .onClick(() => { this.animate(); })
      }
      Text($r('app.string.home_unread_count', this.unread))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor(this.brand())
      Text(this.t1.length > 0 ? this.t1 : $r('app.string.widget_empty'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .onClick(() => { this.openArticle(); })
    }
    .width('100%')
    .height('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
  }
}
