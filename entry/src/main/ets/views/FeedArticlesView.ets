/*
 * FeedArticlesView.ets — 单个订阅源的文章列表（NavDestination 内容，纯展示 + 事件上报）。
 *
 * 从 FeedViewModel 读取当前选中的订阅源（detailFeedId / detailFeedTitle）与其文章
 * （feedArticles，按发布时间倒序）。列表支持按时间排序：默认最新在前，按钮可切换为最早在前
 * ——升/降序只在视图本地重排，不改动 ViewModel。
 */

import { Article } from '../model/Feed';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { ArticleDataSource, articleRowKey } from '../viewmodel/ArticleDataSource';
import { ArticleListItem } from './ArticleListItem';
import { FeedError } from '../common/constants/RssConstants';
import { appSettings } from '../model/AppSettings';
import { MaterialController } from '../service/MaterialController';
import { FeedErrorText } from '../common/utils/FeedErrorText';
import { RouterConstants } from '../common/constants/RouterConstants';
import { CommonConstants } from '../common/constants/CommonConstants';
import { safeArea } from '../service/SafeAreaController';

@ComponentV2
export struct FeedArticlesView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  /** 排序方向：true = 最新在前（默认），false = 最早在前。 */
  @Local newestFirst: boolean = true;
  /** 下拉刷新中（Refresh 组件受控）。 */
  @Local refreshing: boolean = false;
  /** 列表数据源（虚拟化）。 */
  private dataSource: ArticleDataSource = new ArticleDataSource();

  private syncArticles: () => void = () => {
    this.dataSource.setItems(this.ordered());
  };

  aboutToAppear(): void {
    feedViewModel.subscribeArticles(this.syncArticles);
    this.dataSource.setItems(this.ordered());
  }

  aboutToDisappear(): void {
    feedViewModel.unsubscribeArticles(this.syncArticles);
  }

  /** 下拉刷新：只抓当前这个源。 */
  private reload(): void {
    this.refreshing = true;
    feedViewModel.refreshCurrentFeed(true).then(() => {
      this.refreshing = false;
    });
  }

  /** 本地排序：对 ViewModel 的倒序列表做升/降序拷贝（读取 @Trace feedArticles 建立刷新依赖）。 */
  private ordered(): Article[] {
    const list: Article[] = feedViewModel.feedArticles.slice();
    const desc: boolean = this.newestFirst;
    list.sort((a: Article, b: Article): number => {
      return desc ? b.publishedAt - a.publishedAt : a.publishedAt - b.publishedAt;
    });
    return list;
  }

  private openArticle(article: Article): void {
    feedViewModel.openArticle(article.id);
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_ARTICLE, ''));
  }

  /** 列表左滑操作：收藏 / 已读切换（ArkUI 原生 swipeAction，V2 组件可用）。 */
  @Builder
  SwipeActions(article: Article) {
    Row({ space: $r('app.float.space_s') }) {
      Button(article.starred ? $r('app.string.action_unstar') : $r('app.string.action_star'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_on_brand'))
        .backgroundColor($r('app.color.hm_brand'))
        .height('100%')
        .onClick(() => {
          feedViewModel.toggleStar(article.id);
        })
      Button(article.read ? $r('app.string.action_mark_unread') : $r('app.string.action_mark_read'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_on_brand'))
        .backgroundColor($r('app.color.hm_text_secondary'))
        .height('100%')
        .onClick(() => {
          feedViewModel.toggleRead(article.id);
        })
    }
    .height('100%')
    .padding({ left: $r('app.float.space_s') })
  }

  /** 顶部信息行：透明标题栏占位 + 订阅源标题 + 文章数 + 时间排序切换（随列表一起滚动）。 */
  @Builder
  Header() {
    Column({ space: $r('app.float.space_m') }) {
      // 透明标题栏占位：首屏顶部预留「状态栏 + 标题栏」高度，滚动时随内容上移，内容即可穿过标题栏下方。
      Row().width('100%').height(safeArea.contentTopInsetVp)

      Row({ space: $r('app.float.space_s') }) {
        Column({ space: $r('app.float.space_xs') }) {
          Text(feedViewModel.detailFeedTitle)
            .fontSize($r('app.float.font_size_section'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.hm_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text($r('app.string.subs_article_count', feedViewModel.feedArticles.length))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(this.newestFirst ? $r('app.string.feed_sort_newest') : $r('app.string.feed_sort_oldest'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .onClick(() => {
            this.newestFirst = !this.newestFirst;
            this.dataSource.setItems(this.ordered());
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Refresh({ refreshing: this.refreshing }) {
    // 单列表承载「页头 + 文章项」，整页随列表滚动穿过透明标题栏（与首页一致）。
    List({ scroller: this.scroller }) {
      ListItem() {
        this.Header()
      }

      if (feedViewModel.loading && feedViewModel.feedArticles.length === 0) {
        // 首屏加载：这个源还没抓到内容时给个明确状态（以前是空白 + 空态文案打架）
        ListItem() {
          Text($r('app.string.home_loading'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding($r('app.float.space_2xl'))
        }
      } else if (feedViewModel.errorCode !== FeedError.NONE && feedViewModel.feedArticles.length === 0) {
        // 错误态：显示具体原因 + 重试
        ListItem() {
          Column({ space: $r('app.float.space_m') }) {
            Text(FeedErrorText.of(feedViewModel.errorCode))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_danger'))
              .textAlign(TextAlign.Center)
            Button($r('app.string.action_retry'))
              .buttonStyle(ButtonStyleMode.NORMAL)
              .fontColor($r('app.color.hm_on_brand'))
              .backgroundColor($r('app.color.hm_brand'))
              .onClick(() => {
                this.reload();
              })
          }
          .width('100%')
          .padding($r('app.float.space_2xl'))
          .alignItems(HorizontalAlign.Center)
        }
      } else if (feedViewModel.feedArticles.length === 0) {
        ListItem() {
          Text($r('app.string.home_empty_title'))
            .fontSize($r('app.float.font_size_title'))
            .fontColor($r('app.color.hm_text_primary'))
            .padding($r('app.float.space_2xl'))
        }
      } else {
        // 虚拟化：单个源也可能上百条
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
          .swipeAction({ end: this.SwipeActions(item) })
        }, (item: Article) => articleRowKey(item))
      }

      // 无页签栏的详情页：底部预留系统导航条高度。
      ListItem() {
        Row().width('100%').height(safeArea.bottomInsetVp)
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    // 内容穿透透明标题栏：超出列表范围的部分不裁剪，滚到标题栏下方的列表项也不被回收。
    .clip(false)
    .cachedCount(3, true)
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    }
    // 下拉刷新：必须由 onRefreshing 驱动并复位 refreshing，否则指示器停在顶部不复位。
    .onRefreshing(() => {
      this.reload();
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
