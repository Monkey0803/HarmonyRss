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

  /**
   * 读了一半（进度比例 2%–98%）：用来在标题下补一条细进度线，提示「可以接着读」。
   * 不看已读状态 —— 打开即标已读，若加 unread 限制这条提示几乎永远不会出现；
   * 读完（触底）会把比例清零，线也就自动消失。
   */
  private halfRead(): boolean {
    return this.article.progressRatio > 0.02 && this.article.progressRatio < 0.98;
  }

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

        // 读了一半的条目：标题下面补一条细进度线（同类阅读器的「半读」标记）。
        if (this.halfRead()) {
          Row() {
            Row()
              .width(Math.round(this.article.progressRatio * 100) + '%')
              .height($r('app.float.read_progress_height'))
              .backgroundColor($r('app.color.hm_text_secondary'))
              .borderRadius($r('app.float.read_progress_height'))
          }
          .width('100%')
          .height($r('app.float.read_progress_height'))
          .backgroundColor($r('app.color.hm_divider'))
          .borderRadius($r('app.float.read_progress_height'))
        }
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
      // 命中区用 padding 撑到 ~46vp（图标 22vp，接近 48vp 的最小点击区建议）：命中区太小
      // 容易点空，点空会落到整行的 onClick 上把文章打开并标已读 —— 表现为「收藏点不动 / 阅读状态不对」。
      SymbolGlyph(this.article.starred ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.article.starred ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
        .padding($r('app.float.space_m'))
        .accessibilityText(this.article.starred ? $r('app.string.action_unstar') : $r('app.string.action_star'))
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
