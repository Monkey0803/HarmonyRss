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
import { DeepLinkParams } from '../service/DeepLink';

@Entry
@ComponentV2
struct RssWidgetCard {
  @Local unread: number = 0;
  @Local t1: string = '';
  @Local t2: string = '';
  @Local t3: string = '';
  /** 与 t1/t2/t3 一一对应的文章 id：点标题时带着它拉起应用深链到该文章。 */
  @Local i1: string = '';
  @Local i2: string = '';
  @Local i3: string = '';
  /** 最近同步时间（HH:mm），由提供方从本地库的最近抓取时间算好下发。 */
  @Local sync: string = '';
  /** 卡片尺寸语义值：small（2*2）/ large（2*4）。由提供方下发，默认按大卡片渲染。 */
  @Local dimension: string = WidgetConstants.DIMENSION_LARGE;

  private isSmall(): boolean {
    return this.dimension === WidgetConstants.DIMENSION_SMALL;
  }

  /**
   * 点标题：带着文章 id 拉起应用并直达详情（id 为空时退化成只打开应用）。
   * params 必须是显式声明类型的对象：ArkTS 不允许无类型对象字面量。
   */
  private openArticle(articleId: string): void {
    const params: Record<string, Object> = {};
    if (articleId.length > 0) {
      params[DeepLinkParams.ARTICLE_ID] = articleId;
    }
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: params
    });
  }

  /** 通知提供方按本地库最新数据重刷卡片（卡片刷新按钮用）。 */
  private requestRefresh(): void {
    const params: Record<string, Object> = {};
    params[WidgetConstants.PARAM_EVENT] = WidgetConstants.EVENT_REFRESH;
    postCardAction(this, {
      action: 'message',
      params: params
    });
  }

  @Builder
  TitleLine(text: string, articleId: string) {
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
    .onClick(() => {
      this.openArticle(articleId);
    })
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

      // 刷新按钮：只让提供方重读本地库（卡片进程无法联网抓取，联网交给后台任务）。
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor([$r('app.color.hm_text_secondary')])
        .padding({ left: $r('app.float.space_xs') })
        .accessibilityText($r('app.string.widget_refresh'))
        .onClick(() => {
          this.requestRefresh();
        })
    }
    .width('100%')
  }

  build() {
    Column({ space: $r('app.float.space_s') }) {
      this.Header()

      if (this.t1.length > 0) {
        this.TitleLine(this.t1, this.i1)
      } else {
        this.EmptyHint()
      }

      // 2*2 只放一条标题；2*4 再补两条，避免小卡片内容溢出。
      if (!this.isSmall()) {
        if (this.t2.length > 0) {
          this.TitleLine(this.t2, this.i2)
        }
        if (this.t3.length > 0) {
          this.TitleLine(this.t3, this.i3)
        }
        // 2*4 才放「最近同步」：小卡片没地方，放了必然溢出。
        if (this.sync.length > 0) {
          Text($r('app.string.home_last_sync', this.sync))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(1)
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
