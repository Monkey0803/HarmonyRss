/*
 * ArticleListItem.ets — 阅读列表的单行（纯 V2）。
 *
 * 状态管理 V2：本组件是 @ComponentV2，只依赖 @Param / @Event。
 * 刻意**不使用** HDS 的 HdsListItem —— 它是 V1 @Component（内部用 @BuilderParam + V1 状态），
 * 与「应用只支持状态管理 V2」的要求冲突（此前也正是它导致 customItemBuilder 里 this 丢失而崩溃）。
 * 行内容全部自绘；横滑操作由父级的 ListItem.swipeAction 提供（ArkUI 原生能力，V2 组件可用）。
 */

import { Article } from '../model/Feed';
import { DateUtil } from '../common/utils/DateUtil';

@ComponentV2
export struct ArticleListItem {
  @Require @Param article: Article;
  /** 打开详情（父级负责标记已读 + 路由）。 */
  @Event onOpen: () => void = () => {};
  /** 切换收藏。 */
  @Event onToggleStar: (id: string) => void = () => {};

  build() {
    Row({ space: $r('app.float.space_m') }) {
      Row()
        .width($r('app.float.feed_dot_size'))
        .height($r('app.float.feed_dot_size'))
        .backgroundColor(this.article.read ? $r('app.color.hm_divider') : $r('app.color.hm_brand'))
        .borderRadius($r('app.float.feed_dot_size'))

      Column({ space: $r('app.float.space_xs') }) {
        Text(this.article.title)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .fontWeight(this.article.read ? FontWeight.Regular : FontWeight.Bold)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (this.article.summary.length > 0) {
          Text(this.article.summary)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }

        Row({ space: $r('app.float.space_s') }) {
          Text(this.article.feedTitle)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_brand'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.article.author.length > 0) {
            Text(this.article.author)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(DateUtil.format(this.article.publishedAt))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 配图缩略图（feed 里带 media:content / enclosure / 首图时才有）。
      if (this.article.imageUrl.length > 0) {
        Image(this.article.imageUrl)
          .width($r('app.float.thumb_size'))
          .height($r('app.float.thumb_size'))
          .objectFit(ImageFit.Cover)
          .borderRadius($r('app.float.radius_menu_item'))
          .interpolation(ImageInterpolation.Medium)
      }

      // 收藏 / 稍后读：与整行点击互不干扰。
      SymbolGlyph(this.article.starred ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.article.starred ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
        .padding($r('app.float.space_xs'))
        .onClick(() => {
          this.onToggleStar(this.article.id);
        })
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .onClick(() => {
      this.onOpen();
    })
  }
}
