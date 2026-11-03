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
import { ArticleDataSource, ArticleGroup, articleRowKey } from '../viewmodel/ArticleDataSource';
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
import { TagPickerSheet } from './TagPickerSheet';
import { tagViewModel } from '../viewmodel/TagViewModel';
import { ToastUtil } from '../common/utils/ToastUtil';
import { common } from '@kit.AbilityKit';
import { ShareSheet } from './ShareSheet';
import { ShareContext } from '../model/Share';
import { shareService } from '../service/ShareService';
import { shareViewModel } from '../viewmodel/ShareViewModel';
import { frameRateSampler } from '../service/FrameRateSampler';
import { KeyCode } from '@kit.InputKit';
import { AppMenu } from '../common/components/AppMenu';
import { AppSheet } from '../common/components/AppSheet';
import { MenuItemSpec, MenuSectionSpec, MenuSpec } from '../common/components/MenuSpec';
import { ArticleSwipeBar } from '../common/components/ArticleSwipeBar';
import { themePalette } from '../model/ThemePalette';

@ComponentV2
export struct HomeTabView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  @Local refreshing: boolean = false;
  /**
   * 半模态内容类型：'' 关闭 / 'tags' 批量打标 / 'share' 统一分享面板。
   * 一个 AppSheet 宿主只能挂一个半模态，两种面板必须共用同一份显隐状态。
   */
  @Local sheetMode: string = '';
  /** 半模态显隐（传给 AppSheet 的 visible）。 */
  @Local showSheet: boolean = false;
  /** 「添加订阅源」入口在悬浮页签栏的 miniBar 上（Index 持有面板），这里只发请求。 */
  @Event onAddFeedRequest: () => void = () => {};
  /** 列表数据源（LazyForEach 虚拟化用）。 */
  private dataSource: ArticleDataSource = new ArticleDataSource();

  /**
   * 列表内容变化时同步到数据源：ViewModel 负责筛选/排序/分页，这里只管把结果灌进去。
   * 必须每次都灌：文章的已读 / 收藏是原地改字段，数组引用不变，只比较引用会漏掉这类变更。
   */
  private syncArticles: () => void = () => {
    this.dataSource.setItems(feedViewModel.articles);
  };

  aboutToAppear(): void {
    feedViewModel.subscribeArticles(this.syncArticles);
    this.dataSource.setItems(feedViewModel.articles);
  }

  aboutToDisappear(): void {
    feedViewModel.unsubscribeArticles(this.syncArticles);
    frameRateSampler.stop();
  }

  private async reload(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    // 下拉刷新是用户手动动作：force=true 绕过源级间隔（停用源仍然跳过）。
    await feedViewModel.refreshAll(true);
    this.refreshing = false;
  }

  /** 列表快捷键：/ 打开全局搜索（其余按键留给系统 / 详情页）。 */
  private handleListKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (event.keyCode === KeyCode.KEYCODE_SLASH || event.keyCode === 53) {
      this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_SEARCH, ''));
      return true;
    }
    return false;
  }

  private openArticle(article: Article): void {
    feedViewModel.openArticle(article.id);
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_ARTICLE, ''));
  }

  private hostContext(): common.UIAbilityContext {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    return context as common.UIAbilityContext;
  }

  /** 打开半模态并指定内容类型（'' 之外都走这里，保证显隐与内容同步）。 */
  private openSheet(mode: string): void {
    this.sheetMode = mode;
    this.showSheet = true;
  }

  private closeSheet(): void {
    this.showSheet = false;
    this.sheetMode = '';
  }

  /**
   * 列表左滑「分享」：上下文是该行文章（不是当前打开的详情文章）。
   * 先把 Article 转成 ShareContext 写入 ShareViewModel，再翻起面板。
   */
  private async openShare(article: Article): Promise<void> {
    const ctx: ShareContext = await shareService.articleContext(article);
    await shareViewModel.open(this.hostContext(), ctx);
    this.openSheet('share');
  }

  private emptyTitle(): ResourceStr {
    if (feedViewModel.filter === ArticleFilter.UNREAD) {
      return $r('app.string.filter_empty_unread');
    }
    if (feedViewModel.filter === ArticleFilter.STARRED) {
      return $r('app.string.filter_empty_starred');
    }
    return $r('app.string.home_empty_title');
  }

  /**
   * 列表首条：刷新 + 同步时间 + 未读数 + 全部已读 + 排序 / 搜索。
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
            : themePalette.accent()])
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
            // 窄屏只让这一项收缩（省略号），未读数 / 全部已读 / 右侧图标不会被挤出去
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
        }

        Text($r('app.string.home_unread_count', feedViewModel.unreadShown))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_primary'))
          .maxLines(1)
          .flexShrink(0)

        // 「全部已读」：紧贴未读计数（同一组语义），从标题栏筛选条移过来 —— 筛选条只留筛选。
        this.MarkAllReadButton()

        Blank()

        // 排序 + 分组：点开菜单选择（图标按当前排序方向旋转）
        SymbolGlyph($r('sys.symbol.arrow_down_and_line_horizontal_and_arrow_up'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([feedViewModel.groupMode === GroupMode.NONE
            ? $r('app.color.hm_text_secondary')
            : themePalette.accent()])
          .padding($r('app.float.space_xs'))
          .rotate({ angle: feedViewModel.newestFirst ? 0 : 180 })
          .accessibilityText($r('app.string.list_sort_toggle'))
          .bindMenu(this.SortMenu(),
            MaterialController.menuOptions({ placement: Placement.BottomRight }, appSettings.immersiveOn))

        // 全局检索：压入独立搜索页（列表内关键词过滤已移除，避免两套搜索并存）。
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([themePalette.accent()])
          .padding($r('app.float.space_xs'))
          .accessibilityText($r('app.string.search_title'))
          .onClick(() => {
            this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_SEARCH, ''));
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
            .accessibilityText($r('app.string.a11y_clear_scope'))
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

  /**
   * 表头的「全部已读」：图标 + 文案的胶囊按钮，紧贴「N 未读」计数（同一组语义）。
   * 原先挂在标题栏筛选条右侧，与筛选项混在一行；筛选条只负责筛选，批量动作归到这里。
   * 没有未读时置灰（保留占位，避免右侧图标左右跳动）。
   */
  @Builder
  MarkAllReadButton() {
    Button({ type: ButtonType.Capsule, stateEffect: true }) {
      Row({ space: $r('app.float.space_xs') }) {
        SymbolGlyph($r('sys.symbol.checkmark_circle'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([themePalette.accent()])
        Text($r('app.string.home_mark_all_read'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(themePalette.accent())
          .maxLines(1)
      }
      .alignItems(VerticalAlign.Center)
    }
    .height($r('app.float.value_chip_height'))
    .padding({ left: $r('app.float.space_s'), right: $r('app.float.space_m') })
    .backgroundColor($r('app.color.hm_card_background'))
    .flexShrink(0)
    .enabled(feedViewModel.unreadTotal > 0)
    .accessibilityText($r('app.string.home_mark_all_read'))
    .onClick(() => {
      this.confirmMarkAllRead();
    })
  }

  /** 全部已读前确认（与列表里的批量删除同一套对话框样式）。 */
  private confirmMarkAllRead(): void {
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const confirmButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_confirm'),
      fontColor: themePalette.accent(),
      action: () => {
        feedViewModel.markAllRead();
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.mark_all_read_confirm_title'),
      message: $r('app.string.mark_all_read_confirm_message'),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: confirmButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
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
          .backgroundColor(themePalette.fill())
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

  /**
   * 排序 / 分组菜单：两个分区（排序方向、分组方式）各带小标题、各只有一个高亮行。
   *
   * 改造前两组设置挤在一个平铺菜单里，两行同时高亮（图 1）；分区后语义清楚，
   * 视觉统一走 AppMenu（圆角卡片 + 品牌色高亮块）。
   */
  @Builder
  SortMenu() {
    AppMenu(this.sortMenuSpec());
  }

  /** 菜单规格：每次展开现算，读到最新的排序方向与分组方式。 */
  private sortMenuSpec(): MenuSpec {
    const sortItems: MenuItemSpec[] = [
      new MenuItemSpec('newest', $r('app.string.sort_newest'), (): void => {
        feedViewModel.setSort(true);
      }),
      new MenuItemSpec('oldest', $r('app.string.sort_oldest'), (): void => {
        feedViewModel.setSort(false);
      })
    ];
    if (feedViewModel.newestFirst) {
      sortItems[0].markSelected();
    } else {
      sortItems[1].markSelected();
    }
    const groupItems: MenuItemSpec[] = [
      new MenuItemSpec('flat', $r('app.string.group_none'), (): void => {
        feedViewModel.setGroupMode(GroupMode.NONE);
      }),
      new MenuItemSpec('by_feed', $r('app.string.group_by_feed'), (): void => {
        feedViewModel.setGroupMode(GroupMode.FEED);
      }),
      new MenuItemSpec('by_date', $r('app.string.group_by_date'), (): void => {
        feedViewModel.setGroupMode(GroupMode.DATE);
      })
    ];
    if (feedViewModel.groupMode === GroupMode.NONE) {
      groupItems[0].markSelected();
    } else if (feedViewModel.groupMode === GroupMode.FEED) {
      groupItems[1].markSelected();
    } else {
      groupItems[2].markSelected();
    }
    return MenuSpec.fromSections([
      new MenuSectionSpec(sortItems, $r('app.string.menu_section_sort')),
      new MenuSectionSpec(groupItems, $r('app.string.menu_section_group'))
    ]);
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
          .fontColor(themePalette.accent())
          .padding($r('app.float.space_s'))
          .onClick(() => {
            feedViewModel.selectAllVisible();
          })
        Text($r('app.string.select_done'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(themePalette.accent())
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
        this.SelectionAction($r('app.string.tag_title'), () => {
          this.openSheet('tags');
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
      .fontColor(themePalette.accent())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding({ top: $r('app.float.space_s'), bottom: $r('app.float.space_s') })
      .onClick(() => {
        action();
      })
  }

  /** 批量打标面板：选中标签后把当前选中的文章全部关联上。 */
  @Builder
  TagSheet() {
    TagPickerSheet({
      selectedTagIds: [],
      onConfirm: (ids: string[]) => {
        this.closeSheet();
        this.applyTags(ids);
      }
    })
  }

  /** 统一分享面板（三处入口复用同一个 ShareSheet）。 */
  @Builder
  ShareSheetContent() {
    ShareSheet({
      ability: this.hostContext(),
      onClose: () => {
        this.closeSheet();
        shareViewModel.close();
      }
    })
  }

  /** 半模态内容分派：同一时刻只有一种（一个 AppSheet 宿主只能挂一个半模态）。 */
  @Builder
  SheetContent() {
    if (this.sheetMode === 'tags') {
      this.TagSheet()
    } else {
      this.ShareSheetContent()
    }
  }

  /**
   * 批量打标：逐个标签关联全部选中文章（INSERT OR IGNORE，重复添加不产生重复行），
   * 完成后退出多选并提示成功篇数。
   */
  private async applyTags(tagIds: string[]): Promise<void> {
    const ids: string[] = feedViewModel.selectedIds.slice();
    if (ids.length === 0 || tagIds.length === 0) {
      return;
    }
    for (let i = 0; i < tagIds.length; i += 1) {
      await tagViewModel.addTagsToArticles(ids, tagIds[i]);
    }
    ToastUtil.show(this.getUIContext(), $r('app.string.tag_batch_done', ids.length));
    feedViewModel.exitSelect();
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

  /**
   * 列表左滑操作：4 个直达（分享 / 稍后读 / 已读 / 更多），离线动作与「只看该源」收进「更多」菜单。
   * 原来 7 个动作平铺会超出列表项可用宽度，后面两项被裁掉、点不到；现在收口到
   * common/components/ArticleSwipeBar.ets，首页与订阅源详情列表共用同一份实现。
   * 收藏不在左滑里 —— 行内右侧星标已经在切换同一个 starred，不做两处入口。
   */
  @Builder
  SwipeActions(article: Article) {
    ArticleSwipeBar({
      article: article,
      showShare: true,
      showScopeFeed: true,
      onShare: (target: Article) => {
        this.openShare(target);
      }
    })
  }

  build() {
    Stack() {
      Column() {
        this.HomeBody()
        // 固定在滚动视口外，让文章行始终停在悬浮页签栏上方。
        Row().width('100%').height(safeArea.contentBottomInsetVp)
      }
      .width('100%')
      .height('100%')

      // 批量打标 / 分享面板共用同一个半模态宿主（标签选择在「标签」按钮、分享在左滑动作里打开）。
      AppSheet({
        visible: this.showSheet,
        initialSize: this.sheetMode === 'share' ? SheetSize.LARGE : SheetSize.MEDIUM,
        onDismiss: () => {
          const mode: string = this.sheetMode;
          this.showSheet = false;
          this.sheetMode = '';
          if (mode === 'share') {
            shareViewModel.close();
          }
        }
      }) {
        this.SheetContent()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 列表主体：原先的 build 内容（半模态宿主独立在同级 Stack，不再挂在 Refresh 上）。 */
  @Builder
  HomeBody() {
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
            }, (item: Article) => articleRowKey(item))
          } else {
            // 分组：组头吸顶，组内条目仍然虚拟化
            ForEach(feedViewModel.groups, (group: ArticleGroup) => {
              ListItemGroup({ header: this.GroupHeader(group) })
                .divider({ strokeWidth: 0 })
                .margin({ bottom: $r('app.float.space_s') })

              LazyForEach(group.source, (item: Article) => {
                this.ArticleRow(item)
              }, (item: Article) => articleRowKey(item))
            }, (group: ArticleGroup) => group.key + '_' + feedViewModel.articlesRevision)
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
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      // 键盘：列表持焦时 / 直接打开搜索；触屏点击空白处也会让列表重新获得焦点。
      .focusable(true)
      .focusOnTouch(true)
      .defaultFocus(true)
      .onKeyEvent((event: KeyEvent): boolean => {
        return this.handleListKey(event);
      })
      // 列表帧率采样：用户开始滚动时开一个 2s 窗口（30s 内最多一次，诊断关闭时跳过）。
      .onScrollStart(() => {
        frameRateSampler.start();
      })
      // 触底续页：多加载一屏
      .onReachEnd(() => {
        if (!feedViewModel.selecting) {
          feedViewModel.loadMore();
        }
      })
      // 列表在标题栏下方滚动，但在底部页签栏上方截住内容。
      .clip(true)
      .cachedCount(3, true)
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    }
    // 下拉刷新：必须由 onRefreshing 驱动刷新并复位 refreshing，否则指示器会一直停在顶部、
    // 内容被顶下去不复位（表现为「下拉刷新后标题与品牌行间距不对」）。
    .onRefreshing(() => {
      this.reload();
    })
    .width('100%')
    .layoutWeight(1)
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
