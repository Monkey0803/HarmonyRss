import { PreviewItem } from '../model/FeedPreview';
import { DateUtil } from '../common/utils/DateUtil';

/** 预览文章只接收当前结果快照，输入与确认仍由面板持有。 */
@ComponentV2
export struct FeedPreviewItems {
  @Param count: number = 0;
  @Param items: PreviewItem[] = [];

  build() {
    Column({ space: $r('app.float.space_m') }) {
      if (this.count === 0) {
        Text($r('app.string.subs_preview_no_items'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
      } else {
        Text($r('app.string.subs_article_count', this.count))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        Text($r('app.string.subs_preview_latest'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        ForEach(this.items, (item: PreviewItem) => {
          Row({ space: $r('app.float.space_s') }) {
            Text(item.title.length > 0 ? item.title : $r('app.string.article_title'))
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.hm_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(DateUtil.format(item.publishedAt))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
          }
          .width('100%')
        }, (item: PreviewItem) => item.title + '|' + item.publishedAt.toString())
      }

    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
