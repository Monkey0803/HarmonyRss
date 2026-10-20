/*
 * HomeTabView.ets — 阅读页签（纯展示 + 事件上报）。
 *
 * 整页只有一个铺满全屏的可滚动 List：首条是表头（刷新 / 未读 / 搜索），
 * 随列表一起滚动，因此内容可以穿过透明标题栏（配合 list 的 clip(false) + cachedCount）。
 * 品牌行与筛选（全部 / 未读 / 收藏）挂在标题栏上，见 views/BrandTitle.ets、views/FilterSegmentBar.ets。
 * 点光源演示台不在这里（位置固定在组件中心、不能放滚动容器），见 views/EffectPreviewView.ets。
 * 业务逻辑全在 FeedViewModel，这里只读状态、上报触摸与点击事件。
 */

import { Article } from '../model/Feed';
import { ArticleDataSource, ArticleGroup } from '../viewmodel/ArticleDataSource';
import { appSettings } from '../model/AppSettings';
import { MaterialController } from '../service/MaterialController';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { CommonConstants } from '../common/constants/CommonConstants';
import { ArticleListItem } from './ArticleListItem';
import { DateUtil } from '../common/utils/DateUtil';
import { RouterConstants } from '../common/constants/RouterConstants';
import { ArticleFilter, FeedError, GroupMode } from '../common/constants/RssConstants';
import { FeedErrorText } from '../common/utils/FeedErrorText';
import { safeArea } from '../service/SafeAreaController';

@ComponentV2
export struct HomeTabView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  @Local refreshing: boolean = false;
  @Local searchOpen: boolean = false;
  /** 「添加订阅源」入口在悬浮页签栏的 miniBar 上（Index 持有面板），这里只发请求。 */
  @Event onAddFeedRequest: () => void = () => {};
  /** 列表数据源（LazyForEach 虚拟化用）。 */
  private dataSource: ArticleDataSource = new ArticleDataSource();

  /**
   * 列表内容变化时同步到数据源：ViewModel 负责筛选/排序/分页，这里只管把结果灌进去。
   * 用 isSame 做一次引用比较，避免每次 publish 都整表重建。
   */
  private syncArticles: () => void = () => {
    const next: Article[] = feedViewModel.articles;
    if (!this.dataSource.isSame(next)) {
      this.dataSource.setItems(next);
    }
  };

  aboutToAppear(): void {
    feedViewModel.subscribeArticles(this.syncArticles);
    this.dataSource.setItems(feedViewModel.articles);
  }

  aboutToDisappear(): void {
    feedViewModel.unsubscribeArticles(this.syncArticles);
  }

  private async reload(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    await feedViewModel.refreshAll();
    this.refreshing = false;
  }

  private openArticle(article: Article): void {
    feedViewModel.openArticle(article.id);
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_ARTICLE, ''));
  }

  private emptyTitle(): ResourceStr {
    if (feedViewModel.keyword.length > 0) {
      return $r('app.string.filter_empty_search');
    }
    if (feedViewModel.filter === ArticleFilter.UNREAD) {
      return $r('app.string.filter_empty_unread');
    }
    if (feedViewModel.filter === ArticleFilter.STARRED) {
      return $r('app.string.filter_empty_starred');
    }
    return $r('app.string.home_empty_title');
  }

  /**
   * 列表首条：刷新 + 未读概览 + 筛选 + 全部已读 + 订阅管理。
   * 这里不使用多参 @Builder —— ArkUI 多参 @Builder 不随状态刷新，筛选选中态会停在旧值。
   */
  @Builder
  Header() {
    Column({ space: $r('app.float.space_m') }) {
      // 透明标题栏占位：首屏顶部预留「状态栏 + 标题栏 + 筛选条」高度，滚动时随内容上移，
      // 列表内容即可穿过透明标题栏下方（品牌行 + 筛选条挂在标题栏上，见 Index）。
      Row().width('100%').height(safeArea.contentTopInsetVp + CommonConstants.FILTER_BAR_HEIGHT_VP)

      if (feedViewModel.selecting) {
        this.SelectionBar()
      } else {
      Row({ space: $r('app.float.space_m') }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([feedViewModel.loading
            ? $r('sys.color.font_tertiary')
            : $r('app.color.hm_brand')])
          .padding($r('app.float.space_s'))
          .enabled(!feedViewModel.loading)
          .accessibilityText($r('app.string.home_refresh'))
          .onClick(() => {
            this.reload();
          })

        // 最近同步时间：抓取完成后更新（lastUpdated 是 @Trace，会驱动这里重建）
        if (feedViewModel.lastUpdated > 0) {
          Text($r('app.string.home_last_sync', DateUtil.clock(feedViewModel.lastUpdated)))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(1)
        }

        Text($r('app.string.home_unread_count', feedViewModel.unreadShown))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_primary'))
          .padding({
            left: $r('app.float.space_m'),
            right: $r('app.float.space_m'),
            top: $r('app.float.space_s'),
            bottom: $r('app.float.space_s')
          })
          .backgroundColor($r('app.color.hm_card_background'))
          .borderRadius($r('app.float.radius_card'))

        Blank()

        // 排序 + 分组：点开菜单选择（图标按当前排序方向旋转）
        SymbolGlyph($r('sys.symbol.arrow_down_and_line_horizontal_and_arrow_up'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([feedViewModel.groupMode === GroupMode.NONE
            ? $r('app.color.hm_text_secondary')
            : $r('app.color.hm_brand')])
          .padding($r('app.float.space_xs'))
          .rotate({ angle: feedViewModel.newestFirst ? 0 : 180 })
          .accessibilityText($r('app.string.list_sort_toggle'))
          .bindMenu(this.SortMenu(),
            MaterialController.menuOptions({ placement: Placement.BottomRight }, appSettings.immersiveOn))

        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([this.searchOpen ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
          .padding($r('app.float.space_xs'))
          .onClick(() => {
            this.searchOpen = !this.searchOpen;
            if (!this.searchOpen) {
              feedViewModel.setKeyword('');
            }
          })
      }
      .width('100%')
      }

      if (this.searchOpen && !feedViewModel.selecting) {
        Row({ space: $r('app.float.space_s') }) {
          TextInput({ text: feedViewModel.keyword, placeholder: $r('app.string.home_search_hint') })
            .type(InputType.Normal)
            .fontSize($r('app.float.font_size_body'))
            .layoutWeight(1)
            .onChange((value: string) => {
              feedViewModel.setKeyword(value);
            })
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize($r('app.float.icon_size'))
            .fontColor([$r('app.color.hm_text_secondary')])
            .padding($r('app.float.space_s'))
            .onClick(() => {
              feedViewModel.setKeyword('');
              this.searchOpen = false;
            })
        }
        .width('100%')
      }

      if (feedViewModel.scopeFeedId.length > 0) {
        Row({ space: $r('app.float.space_s') }) {
          Text($r('app.string.home_scope_prefix', feedViewModel.scopeTitle))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor([$r('app.color.hm_text_secondary')])
            .onClick(() => {
              feedViewModel.clearScope();
            })
        }
        .width('100%')
        .padding({
          left: $r('app.float.space_m'),
          right: $r('app.float.space_m'),
          top: $r('app.float.space_s'),
          bottom: $r('app.float.space_s')
        })
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))
      }

      if (feedViewModel.errorCode !== FeedError.NONE && feedViewModel.articles.length === 0) {
        Text(FeedErrorText.of(feedViewModel.errorCode))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .width('100%')
      }
    }
    .width('100%')
    // 首屏位置由 HDS 的标题栏安全区自动排定，这里只留常规间距。
    .padding({ top: $r('app.float.space_s'), bottom: $r('app.float.space_s') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  EmptyState() {
    Column({ space: $r('app.float.space_m') }) {
      Text(this.emptyTitle())
        .fontSize($r('app.float.font_size_title'))
        .fontColor($r('app.color.hm_text_primary'))

      if (feedViewModel.filter === ArticleFilter.ALL) {
        Text($r('app.string.home_empty_hint'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .textAlign(TextAlign.Center)
        Button($r('app.string.home_empty_action'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .onClick(() => {
            // 「添加订阅源」入口现在挂在悬浮页签栏的 miniBar 上（见 Index），这里只上报请求。
            this.onAddFeedRequest();
          })
      }
    }
    .width('100%')
    .padding($r('app.float.space_2xl'))
    .alignItems(HorizontalAlign.Center)
  }

  /** 排序/分组菜单：两段（排序方向、分组方式），当前项高亮。 */
  @Builder
  SortMenu() {
    Menu() {
      MenuItem(this.MenuItemRow($r('app.string.sort_newest'), feedViewModel.newestFirst, (): void => {
        feedViewModel.setSort(true);
      }))
      MenuItem(this.MenuItemRow($r('app.string.sort_oldest'), !feedViewModel.newestFirst, (): void => {
        feedViewModel.setSort(false);
      }))
      MenuItem(this.MenuItemRow($r('app.string.group_none'), feedViewModel.groupMode === GroupMode.NONE, (): void => {
        feedViewModel.setGroupMode(GroupMode.NONE);
      }))
      MenuItem(this.MenuItemRow($r('app.string.group_by_feed'), feedViewModel.groupMode === GroupMode.FEED, (): void => {
        feedViewModel.setGroupMode(GroupMode.FEED);
      }))
      MenuItem(this.MenuItemRow($r('app.string.group_by_date'), feedViewModel.groupMode === GroupMode.DATE, (): void => {
        feedViewModel.setGroupMode(GroupMode.DATE);
      }))
    }
    // 不设宽度时菜单会按「两列栅格」撑得很宽，这里收成一条紧凑菜单。
    .width($r('app.float.menu_width'))
    .radius($r('app.float.radius_card'))
  }

  /**
   * 菜单项内容：选中项用品牌色 + 高亮底。
   *
   * 两个坑：
   * 1) 高度必须给定值 —— MenuItem 的内容区没有可用的父高度，height('100%') 会被解析成无穷大，
   *    菜单被撑成一条超出屏幕的长面板（只剩第一项可见）；
   * 2) 点击要挂在**内容行**上，MenuItem(...) 上挂的 onClick 不会触发（与设置页的选项菜单一致）。
   */
  @Builder
  MenuItemRow(label: ResourceStr, selected: boolean, action: () => void) {
    Row() {
      Text(label)
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(selected ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(selected ? $r('app.color.hm_brand') : $r('app.color.hm_text_primary'))
    }
    .width('100%')
    .height($r('app.float.menu_item_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    .alignItems(VerticalAlign.Center)
    .margin({ left: $r('app.float.space_xs'), right: $r('app.float.space_xs') })
    .backgroundColor(selected ? $r('app.color.hm_menu_item_selected') : $r('app.color.hm_page_transparent'))
    .borderRadius($r('app.float.radius_menu_item'))
    .onClick(() => {
      action();
    })
  }

  /** 分组视图的组头：组名 + 未读数。 */
  @Builder
  GroupHeader(group: ArticleGroup) {
    Row({ space: $r('app.float.space_s') }) {
      Text(group.title)
        .fontSize($r('app.float.font_size_caption'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (group.unread > 0) {
        Text($r('app.string.list_group_unread', group.unread))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_s'),
      top: $r('app.float.space_s'),
      bottom: $r('app.float.space_s')
    })
  }

  /** 组内一条文章（平铺与分组共用同一种行）。 */
  @Builder
  ArticleRow(item: Article) {
    ListItem() {
      ArticleListItem({
        article: item,
        selecting: feedViewModel.selecting,
        picked: feedViewModel.selectedIds.indexOf(item.id) >= 0,
        onOpen: () => {
          // 多选态下点行 = 勾选 / 取消勾选，不打开详情
          if (feedViewModel.selecting) {
            feedViewModel.toggleSelect(item.id);
          } else {
            this.openArticle(item);
          }
        },
        onLongPress: () => {
          feedViewModel.beginSelect(item.id);
        },
        onToggleStar: (id: string) => {
          feedViewModel.toggleStar(id);
        }
      })
    }
    .margin({ bottom: $r('app.float.space_s') })
    .swipeAction({ end: this.SwipeActions(item) })
  }

  /**
   * 多选工具条：选中数量 + 全选 / 完成，下面一行是批量动作。
   * 长按进入后出现在列表首条（选择模式里不再显示刷新 / 筛选那一行，避免两套入口打架）。
   */
  @Builder
  SelectionBar() {
    Column({ space: $r('app.float.space_s') }) {
      Row({ space: $r('app.float.space_m') }) {
        Text($r('app.string.select_count', feedViewModel.selectedIds.length))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_primary'))
        Blank()
        Text($r('app.string.select_all'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .padding($r('app.float.space_s'))
          .onClick(() => {
            feedViewModel.selectAllVisible();
          })
        Text($r('app.string.select_done'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .padding($r('app.float.space_s'))
          .onClick(() => {
            feedViewModel.exitSelect();
          })
      }
      .width('100%')

      Row({ space: $r('app.float.space_s') }) {
        this.SelectionAction($r('app.string.action_mark_read'), () => {
          feedViewModel.markReadMany(feedViewModel.selectedIds, true);
        })
        this.SelectionAction($r('app.string.action_mark_unread'), () => {
          feedViewModel.markReadMany(feedViewModel.selectedIds, false);
        })
        this.SelectionAction($r('app.string.filter_starred'), () => {
          feedViewModel.markStarredMany(feedViewModel.selectedIds, true);
        })
        this.SelectionAction($r('app.string.filter_saved'), () => {
          feedViewModel.markSavedMany(feedViewModel.selectedIds, true);
        })
        this.SelectionAction($r('app.string.action_mark_above_read'), () => {
          feedViewModel.markAboveRead(feedViewModel.anchorId);
        })
        this.SelectionAction($r('app.string.action_delete'), () => {
          this.confirmDeleteSelected();
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  /** 多选里的一个动作按钮（等分宽度，文案短）。 */
  @Builder
  SelectionAction(label: ResourceStr, action: () => void) {
    Text(label)
      .fontSize($r('app.float.font_size_caption'))
      .fontColor($r('app.color.hm_brand'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding({ top: $r('app.float.space_s'), bottom: $r('app.float.space_s') })
      .onClick(() => {
        action();
      })
  }

  /** 批量删除确认。 */
  private confirmDeleteSelected(): void {
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const confirmButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_confirm'),
      fontColor: $r('app.color.hm_danger'),
      action: () => {
        feedViewModel.deleteMany(feedViewModel.selectedIds);
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.delete_selected_confirm_title'),
      message: $r('app.string.delete_selected_confirm_message', feedViewModel.selectedIds.length),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: confirmButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
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
      Button(article.saved ? $r('app.string.action_unsave') : $r('app.string.action_save'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_on_brand'))
        .backgroundColor($r('app.color.hm_brand'))
        .height('100%')
        .onClick(() => {
          feedViewModel.toggleSaved(article.id);
        })
      // 只看该源：把首页收敛到这个来源（列表里就能用，不必先进详情页）
      Button($r('app.string.action_scope_feed'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_on_brand'))
        .backgroundColor($r('app.color.hm_text_secondary'))
        .height('100%')
        .onClick(() => {
          feedViewModel.scopeToFeedById(article.feedId);
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

  build() {
    Refresh({ refreshing: this.refreshing }) {
      List({ scroller: this.scroller }) {
        ListItem() {
          this.Header()
        }

        if (feedViewModel.loading && feedViewModel.articles.length === 0) {
          ListItem() {
            Text($r('app.string.home_loading'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .padding($r('app.float.space_2xl'))
          }
        } else if (feedViewModel.articles.length === 0) {
          ListItem() {
            this.EmptyState()
          }
        } else {
          if (feedViewModel.groupMode === GroupMode.NONE) {
            // 虚拟化：只构建可见区域附近的条目（配合 ViewModel 的分页，条数多也不掉帧）
            LazyForEach(this.dataSource, (item: Article) => {
              this.ArticleRow(item)
            }, (item: Article) => item.id)
          } else {
            // 分组：组头吸顶，组内条目仍然虚拟化
            ForEach(feedViewModel.groups, (group: ArticleGroup) => {
              ListItemGroup({ header: this.GroupHeader(group) })
                .divider({ strokeWidth: 0 })
                .margin({ bottom: $r('app.float.space_s') })

              LazyForEach(group.source, (item: Article) => {
                this.ArticleRow(item)
              }, (item: Article) => item.id)
            }, (group: ArticleGroup) => group.key)
          }

          // 触底续页：还有下一屏时给一条提示尾行（滚到底自动加载）
          if (feedViewModel.hasMore()) {
            ListItem() {
              Text($r('app.string.list_load_more'))
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_text_secondary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding($r('app.float.space_l'))
            }
          }
        }

        // 底部预留：避让悬浮页签栏与系统导航条。
        ListItem() {
          Row()
            .width('100%')
            .height(safeArea.contentBottomInsetVp)
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      // 触底续页：多加载一屏
      .onReachEnd(() => {
        if (!feedViewModel.selecting) {
          feedViewModel.loadMore();
        }
      })
      // 内容穿透标题栏：超出列表范围的部分不裁剪，滚到标题栏下方的列表项也不会被回收。
      .clip(false)
      .cachedCount(3, true)
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    }
    // 下拉刷新：必须由 onRefreshing 驱动刷新并复位 refreshing，否则指示器会一直停在顶部、
    // 内容被顶下去不复位（表现为「下拉刷新后标题与品牌行间距不对」）。
    .onRefreshing(() => {
      this.reload();
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
