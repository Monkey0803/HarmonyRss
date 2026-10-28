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
import { appSettings } from '../model/AppSettings';
import { ListDensityMetrics, ListRowLayout } from '../common/constants/SettingsConstants';
import { Enclosure, firstAudio, firstVideo, formatDuration } from '../model/Enclosure';

@ReusableV2
@ComponentV2
export struct ArticleListItem {
  @Require @Param article: Article;
  /** 打开详情（父级负责标记已读 + 路由）。 */
  @Event onOpen: () => void = () => {};
  /** 切换收藏。 */
  @Event onToggleStar: (id: string) => void = () => {};
  /** 长按进入多选。 */
  @Event onLongPress: () => void = () => {};
  /** 父级是否处于多选模式。 */
  @Param selecting: boolean = false;
  /** 本行是否被选中（仅多选模式有意义）。 */
  @Param picked: boolean = false;

  /** 摘要最多几行（设置页可配 1/2/3）。 */
  private summaryLines(): number {
    return ListDensityMetrics.summaryLines(appSettings.listSummaryLines);
  }

  /** 行内边距（随密度：紧凑 / 标准 / 宽松）。 */
  private rowPadding(): Resource {
    return ListDensityMetrics.padding(appSettings.listDensity);
  }

  /** 是否用「顶部大图」卡片样式（无图时自动退回缩略图/纯文字，避免空一块）。 */
  private largeImage(): boolean {
    return appSettings.listRowLayout === ListRowLayout.CARD && this.article.imageUrl.length > 0;
  }

  /** 是否显示右侧缩略图。 */
  private thumbImage(): boolean {
    return appSettings.listRowLayout === ListRowLayout.THUMB && this.article.imageUrl.length > 0;
  }

  /**
   * 读了一半（进度比例 2%–98%）：用来在标题下补一条细进度线，提示「可以接着读」。
   * 不看已读状态 —— 打开即标已读，若加 unread 限制这条提示几乎永远不会出现；
   * 读完（触底）会把比例清零，线也就自动消失。
   */
  private halfRead(): boolean {
    return this.article.progressRatio > 0.02 && this.article.progressRatio < 0.98;
  }

  /** 屏幕阅读器使用的列表行状态说明（已收藏优先于已读 / 未读）。 */
  private accessibilityState(): Resource {
    if (this.selecting) {
      return this.picked ? $r('app.string.a11y_row_selected') : $r('app.string.a11y_row_not_selected');
    }
    if (this.article.starred) {
      return $r('app.string.a11y_article_starred');
    }
    return this.article.read
      ? $r('app.string.a11y_article_read')
      : $r('app.string.a11y_article_unread');
  }

  /** 是否是多来源合并出的主条（duplicateCount 含自己，>1 表示还有别的源收录）。 */
  private merged(): boolean {
    return this.article.duplicateCount > 1;
  }

  /** 列表行的媒体标识（音频优先，其次视频）。 */
  private mediaAudio(): Enclosure | undefined {
    return firstAudio(this.article.enclosures);
  }

  private mediaVideo(): Enclosure | undefined {
    return firstVideo(this.article.enclosures);
  }

  private mediaDurationText(): string {
    const audio: Enclosure | undefined = this.mediaAudio();
    return audio !== undefined && audio.duration > 0
      ? formatDuration(audio.duration) : '';
  }

  build() {
    Column({ space: $r('app.float.space_s') }) {
      // 大图卡片样式：图在上、文在下（feed 没配图时自动退回文字/缩略图，不留空白）
      if (this.largeImage()) {
        Image(this.article.imageUrl)
          .width('100%')
          .height($r('app.float.card_image_height'))
          .objectFit(ImageFit.Cover)
          .borderRadius($r('app.float.radius_menu_item'))
          .interpolation(ImageInterpolation.Medium)
      }

      Row({ space: $r('app.float.space_m') }) {
      if (this.selecting) {
        // 多选态：未读点换成勾选圈（选中的用品牌色实心）
        SymbolGlyph(this.picked ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.circle'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([this.picked ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
          .padding({ left: $r('app.float.space_xs'), right: $r('app.float.space_xs') })
      } else {
        Row()
          .width($r('app.float.feed_dot_size'))
          .height($r('app.float.feed_dot_size'))
          .backgroundColor(this.article.read ? $r('app.color.hm_divider') : $r('app.color.hm_brand'))
          .borderRadius($r('app.float.feed_dot_size'))
      }

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
            .maxLines(this.summaryLines())
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
          // 跨源合并出来的主条：补一枚来源数 chip（纯展示，点击仍然打开文章）。
          if (this.merged()) {
            Text($r('app.string.dedupe_source_count', this.article.duplicateCount))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_brand'))
              .maxLines(1)
              .constraintSize({ maxWidth: 96 })
              .height($r('app.float.value_chip_height'))
              .padding({ left: $r('app.float.space_s'), right: $r('app.float.space_s') })
              .backgroundColor($r('app.color.hm_value_chip_background'))
              .borderRadius($r('app.float.radius_chip'))
          }
          if (this.article.author.length > 0) {
            Text(this.article.author)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (this.mediaAudio() !== undefined) {
            SymbolGlyph($r('sys.symbol.headphones'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor([$r('app.color.hm_brand')])
              .accessibilityText($r('app.string.media_audio_label'))
            if (this.mediaDurationText().length > 0) {
              Text(this.mediaDurationText())
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_brand'))
                .maxLines(1)
            }
          } else if (this.mediaVideo() !== undefined) {
            SymbolGlyph($r('sys.symbol.play_video'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor([$r('app.color.hm_brand')])
              .accessibilityText($r('app.string.media_video_label'))
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
      if (this.thumbImage()) {
        Image(this.article.imageUrl)
          .width(this.largeImage() ? $r('app.float.thumb_size_large') : $r('app.float.thumb_size'))
          .height(this.largeImage() ? $r('app.float.thumb_size_large') : $r('app.float.thumb_size'))
          .objectFit(ImageFit.Cover)
          .borderRadius($r('app.float.radius_menu_item'))
          .interpolation(ImageInterpolation.Medium)
      }

      // 稍后读标记：只是一枚状态图标（切换在左滑 / 批量里做，行内不抢点击）
      if (this.article.saved) {
        SymbolGlyph($r('sys.symbol.bookmark_fill'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor([$r('app.color.hm_brand')])
          .accessibilityText($r('app.string.filter_saved'))
      }

      // 收藏 / 稍后读：与整行点击互不干扰。
      // 命中区用 padding 撑到 ~46vp（图标 22vp，接近 48vp 的最小点击区建议）：命中区太小
      // 容易点空，点空会落到整行的 onClick 上把文章打开并标已读 —— 表现为「收藏点不动 / 阅读状态不对」。
      if (!this.selecting) {
        SymbolGlyph(this.article.starred ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([this.article.starred ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
          .padding($r('app.float.space_m'))
          .accessibilityText(this.article.starred ? $r('app.string.action_unstar') : $r('app.string.action_star'))
          .onClick(() => {
            this.onToggleStar(this.article.id);
          })
      }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .padding(this.rowPadding())
    .backgroundColor(this.selecting && this.picked
      ? $r('app.color.hm_menu_item_selected')
      : $r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .accessibilityDescription(this.accessibilityState())
    .onClick(() => {
      this.onOpen();
    })
    // 长按进多选（多选态里长按不做别的事，避免误触）
    .gesture(LongPressGesture().onAction(() => {
      if (!this.selecting) {
        this.onLongPress();
      }
    }))
  }
}
