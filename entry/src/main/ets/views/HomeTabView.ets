/*
 * HomeTabView.ets — 阅读页签（纯展示 + 事件上报）。
 *
 * 整页只有一个铺满全屏的可滚动 List：首条是表头（刷新 / 未读 / 筛选 / 全部已读 / 订阅管理），
 * 随列表一起滚动，因此内容可以穿过透明标题栏（配合 list 的 clip(false) + cachedCount）。
 * 点光源演示台不在这里（位置固定在组件中心、不能放滚动容器），见 views/EffectPreviewView.ets。
 * 业务逻辑全在 FeedViewModel，这里只读状态、上报触摸与点击事件。
 */

import { Article } from '../model/Feed';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { appSettings } from '../model/AppSettings';
import { AppLogo } from '../common/components/AppLogo';
import { CommonConstants } from '../common/constants/CommonConstants';
import { ArticleListItem } from './ArticleListItem';
import { RouterConstants } from '../common/constants/RouterConstants';
import { ArticleFilter, FeedError } from '../common/constants/RssConstants';
import { FeedErrorText } from '../common/utils/FeedErrorText';
import { ColorMetrics, SegmentButtonV2Items, TabSegmentButtonV2 } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { safeArea } from '../service/SafeAreaController';
import { MaterialController } from '../service/MaterialController';

const DOMAIN: number = 0x0000;
const TAG: string = 'HomeTabView';

/** 筛选值 → 分段控件选中下标。 */
function filterIndexOf(filter: string): number {
  if (filter === ArticleFilter.UNREAD) {
    return 1;
  }
  if (filter === ArticleFilter.STARRED) {
    return 2;
  }
  return 0;
}

/** 分段控件下标 → 筛选值。 */
function filterAt(index: number): string {
  if (index === 1) {
    return ArticleFilter.UNREAD;
  }
  if (index === 2) {
    return ArticleFilter.STARRED;
  }
  return ArticleFilter.ALL;
}

@ComponentV2
export struct HomeTabView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  @Local refreshing: boolean = false;
  @Local searchOpen: boolean = false;
  /** 「添加订阅源」入口在悬浮页签栏的 miniBar 上（Index 持有面板），这里只发请求。 */
  @Event onAddFeedRequest: () => void = () => {};
  /** 筛选分段控件的选项（全部 / 未读 / 收藏）。 */
  private filterItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: $r('app.string.filter_all') },
    { text: $r('app.string.filter_unread') },
    { text: $r('app.string.filter_starred') }
  ]);

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

  /** 全部已读前确认。 */
  private confirmMarkAllRead(): void {
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const confirmButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_confirm'),
      fontColor: $r('app.color.hm_brand'),
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
      // 透明标题栏占位：首屏顶部预留「状态栏 + 标题栏」高度，滚动时随内容上移，列表内容即可穿过透明标题栏下方。
      Row().width('100%').height(safeArea.contentTopInsetVp)

      // 品牌行：显示当前所选 App logo，切换后立即反映。
      Row({ space: $r('app.float.space_s') }) {
        AppLogo({
          logoKind: appSettings.logoKind,
          logoSize: CommonConstants.LOGO_BRAND_SIZE,
          cornerRadius: CommonConstants.LOGO_BRAND_RADIUS
        })
        Text($r('app.string.brand_name'))
          .fontSize($r('app.float.font_size_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.hm_text_primary'))
      }
      .width('100%')

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

      if (this.searchOpen) {
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

      Row({ space: $r('app.float.space_s') }) {
        // 分段控件不支持通用属性，会吃掉所在区域的「最大可用宽度」，直接放进 Row 会把右侧按钮挤成 0 宽。
        // 因此套一层 layoutWeight(1) 的容器：它按固定尺寸的按钮量完后再取剩余宽度，按钮宽度得以保留。
        Row() {
          // 页签型分段按钮。刻意不传 backgroundSystemMaterial：沉浸光感是区域级能力，
          // 只有 Navigation/NavDestination 标题栏与底部 TabBar 等生效区域里的组件才吃材质，
          // 分段控件在内容区，传了只会打 "Material inactive: out of scope"，背板仍是组件自带背景
          // （官方给生效范围外组件的替代方案就是通用背景属性，见沉浸光感 FAQ）。
          TabSegmentButtonV2({
            items: this.filterItems,
            selectedIndex: filterIndexOf(feedViewModel.filter),
            onItemClicked: (index: number) => {
              feedViewModel.setFilter(filterAt(index));
            },
            // 特殊系统资源值：未选中态跟随主题文字色。
            itemFontColor: this.safeColor($r('sys.color.font_primary')),
            itemSelectedFontColor: this.safeColor(Color.Black)
          })
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        Button($r('app.string.home_mark_all_read'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .flexShrink(0)
          .enabled(feedViewModel.unreadTotal > 0)
          .onClick(() => {
            this.confirmMarkAllRead();
          })
      }
      .width('100%')

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

  /**
   * 分段按钮的文本配色。
   *
   * `ColorMetrics.resourceColor` 标注了可能抛异常，ArkTS 要求调用点必须 catch；
   * 这两个参数在 TabSegmentButtonV2 里都是可选的，失败时返回 undefined 退回组件默认样式。
   */
  private safeColor(value: ResourceColor): ColorMetrics | undefined {
    try {
      return ColorMetrics.resourceColor(value);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'resourceColor failed: %{public}d', error.code);
      return undefined;
    }
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
          ForEach(feedViewModel.articles, (item: Article) => {
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
          }, (item: Article) => item.id)
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
