/* Home list empty state; the parent supplies the active filter and add action. */
import { ArticleFilter } from '../common/constants/RssConstants';
import { themePalette } from '../model/ThemePalette';

@ComponentV2
export struct HomeEmptyState {
  @Param filter: string = ArticleFilter.ALL;
  @Event onAddFeed: () => void = () => {};

  private title(): ResourceStr {
    if (this.filter === ArticleFilter.UNREAD) {
      return $r('app.string.filter_empty_unread');
    }
    if (this.filter === ArticleFilter.STARRED) {
      return $r('app.string.filter_empty_starred');
    }
    return $r('app.string.home_empty_title');
  }

  build() {
    Column({ space: $r('app.float.space_m') }) {
      Text(this.title())
        .fontSize($r('app.float.font_size_title'))
        .fontColor($r('app.color.hm_text_primary'))

      if (this.filter === ArticleFilter.ALL) {
        Text($r('app.string.home_empty_hint'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .textAlign(TextAlign.Center)
        Button($r('app.string.home_empty_action'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor(themePalette.fill())
          .onClick(() => {
            this.onAddFeed();
          })
      }
    }
    .width('100%')
    .padding($r('app.float.space_2xl'))
    .alignItems(HorizontalAlign.Center)
  }
}
