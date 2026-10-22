/*
 * TagArticlesView.ets — 标签文章列表页（NavDestination 内容，纯展示 + 事件上报）。
 *
 * 数据来自 TagViewModel（多标签 AND、轻量列、按发布时间倒序分页）；本页不持有筛选状态机，
 * 只把 ViewModel 的结果灌进 LazyForEach 数据源。点击条目沿用 FeedViewModel.openArticleById
 * （必要时从库补全正文）后 push 详情页。
 */

import { Article } from '../model/Feed';
import { TagWithCount } from '../model/Tag';
import { tagViewModel } from '../viewmodel/TagViewModel';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { ArticleDataSource, articleRowKey } from '../viewmodel/ArticleDataSource';
import { ArticleListItem } from './ArticleListItem';
import { RouterConstants } from '../common/constants/RouterConstants';
import { safeArea } from '../service/SafeAreaController';
import { ToastUtil } from '../common/utils/ToastUtil';

@ComponentV2
export struct TagArticlesView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  @Local opening: boolean = false;

  private dataSource: ArticleDataSource = new ArticleDataSource();

  aboutToAppear(): void {
    this.dataSource.setItems(tagViewModel.tagArticles);
    // 从标签页带过来的结果已经拉过第一页；直接进本页（例如深链 / 重建）时兜底再拉一次。
    if (tagViewModel.tagArticles.length === 0 && tagViewModel.activeTags.length > 0) {
      tagViewModel.refreshArticles().then(() => {
        this.dataSource.setItems(tagViewModel.tagArticles);
      });
    }
  }

  private openArticle(article: Article): void {
    if (this.opening) {
      return;
    }
    this.opening = true;
    feedViewModel.openArticleById(article.id).then((ok: boolean) => {
      this.opening = false;
      if (!ok) {
        ToastUtil.show(this.getUIContext(), $r('app.string.hl_article_gone'));
        return;
      }
      this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_ARTICLE, ''));
    }).catch(() => {
      this.opening = false;
      ToastUtil.show(this.getUIContext(), $r('app.string.hl_article_gone'));
    });
  }

  /** 触底续页：追加后重新灌数据源。 */
  private loadMore(): void {
    tagViewModel.loadMoreArticles().then(() => {
      this.dataSource.setItems(tagViewModel.tagArticles);
    });
  }

  @Builder
  Header() {
    Column({ space: $r('app.float.space_m') }) {
      Row().width('100%').height(safeArea.contentTopInsetVp)

      Text($r('app.string.tag_articles_title'))
        .fontSize($r('app.float.font_size_section'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(tagViewModel.activeTags, (tag: TagWithCount) => {
          Text(tag.name)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_brand'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({
              left: $r('app.float.space_m'),
              right: $r('app.float.space_m'),
              top: $r('app.float.space_xs'),
              bottom: $r('app.float.space_xs')
            })
            .margin({ right: $r('app.float.space_s'), bottom: $r('app.float.space_s') })
            .backgroundColor($r('app.color.hm_value_chip_background'))
            .borderRadius($r('app.float.radius_chip'))
        }, (tag: TagWithCount) => tag.id)
      }
      .width('100%')

      Text($r('app.string.subs_article_count', tagViewModel.totalArticles))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    List({ scroller: this.scroller }) {
      ListItem() {
        this.Header()
      }
      .margin({ bottom: $r('app.float.space_s') })

      if (tagViewModel.loading && tagViewModel.tagArticles.length === 0) {
        ListItem() {
          Text($r('app.string.home_loading'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding($r('app.float.space_2xl'))
        }
      } else if (tagViewModel.tagArticles.length === 0) {
        ListItem() {
          Text($r('app.string.search_no_result'))
            .fontSize($r('app.float.font_size_title'))
            .fontColor($r('app.color.hm_text_primary'))
            .padding($r('app.float.space_2xl'))
        }
      } else {
        LazyForEach(this.dataSource, (item: Article) => {
          ListItem() {
            ArticleListItem({
              article: item,
              onOpen: () => {
                this.openArticle(item);
              },
              onToggleStar: (id: string) => {
                feedViewModel.toggleStar(id);
              }
            })
          }
          .margin({ bottom: $r('app.float.space_s') })
        }, (item: Article) => articleRowKey(item))
      }

      if (tagViewModel.hasMore) {
        ListItem() {
          Text($r('app.string.list_load_more'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding($r('app.float.space_l'))
        }
      }

      // 无页签栏：底部只避让系统导航条。
      ListItem() {
        Row().width('100%').height(safeArea.bottomInsetVp)
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .clip(false)
    .cachedCount(3, true)
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    .onReachEnd(() => {
      this.loadMore();
    })
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
