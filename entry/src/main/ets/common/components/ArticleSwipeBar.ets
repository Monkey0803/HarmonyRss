/*
 * ArticleSwipeBar.ets — 阅读列表的行内左滑操作（纯状态管理 V2）。
 *
 * 为什么收口成一个组件：
 *   - 首页（views/HomeTabView.ets）与订阅源详情列表（views/FeedArticlesView.ets）原先各写了一遍
 *     几乎相同的 @Builder，7 个 / 4 个动作横排平铺。单个文案块约 52vp，360vp 屏上列表项可用宽度
 *     只有约 328vp —— 7 个需要 360vp 以上，后面两项直接跑出屏幕，看得到一半却点不到。
 *   - 现在固定 4 个直达块：分享 / 稍后读 / 已读 / 更多；离线动作（下载、重试、清除离线）与
 *     「只看该源」进「更多」下拉菜单，复用 common/components/AppMenu（与阅读页底栏「更多」同一套观感）。
 *     菜单里有哪些条目由 SwipeActionPlan 决定（纯数据，可单测）。
 *   - **左滑不放「收藏」**：行内右侧已经有星标按钮（ArticleListItem 的 onToggleStar），同一动作不做
 *     两处入口；把位置让给「分享」，让它从「左滑 → 更多 → 分享」两步变成一步。
 *
 * 宽度约束（别再改回去）：
 *   - 4 个块定宽 swipe_action_width(72vp)：4×72 + 3×8(space_s) = 312vp ≤ 328vp，留 16vp 余量；
 *   - 每块带 flexShrink(1)：窄屏（320vp）只会收缩 + 文案省略号，不会出现跑出屏幕、点不到的按钮；
 *   - 图标 18vp + 4vp 间距 + 11fp 文案（纵向排布）≈ 40vp，最低行高（紧凑密度）下也放得下。
 *
 * 图标与文案的语义：图标表示「点了会变成的样子」（未收藏 = 空星，已收藏 = 实心星，
 * 已读 = 空心圈），文案是该动作本身（action_mark_read / action_unstar …），
 * accessibilityText 读的是完整动作名，不依赖用户理解图标。
 */

import { Article } from '../../model/Feed';
import { appSettings } from '../../model/AppSettings';
import { feedViewModel } from '../../viewmodel/FeedViewModel';
import { MaterialController } from '../../service/MaterialController';
import { ToastUtil } from '../utils/ToastUtil';
import { AppMenu } from './AppMenu';
import { MenuItemSpec, MenuSectionSpec, MenuSpec } from './MenuSpec';
import { SwipeOverflowId, swipeOverflowIds } from './SwipeActionPlan';
import { themePalette } from '../../model/ThemePalette';

/**
 * 一个左滑直达块的数据。
 * 必须是单参 @Builder 的入参：ArkUI 的多参 @Builder 不随状态刷新（稍后读 / 已读的文案会停在旧值）。
 */
export class SwipePillSpec {
  readonly icon: Resource;
  /** 文案必须是资源（accessibilityText 只接受 string / Resource 两个独立重载，不接受 ResourceStr 联合类型）。 */
  readonly label: Resource;
  /** true = 品牌色底（主操作）；false = 次要色底（更多 / 低频动作）。 */
  readonly primary: boolean;
  readonly action: () => void;

  constructor(icon: Resource, label: Resource, primary: boolean, action: () => void) {
    this.icon = icon;
    this.label = label;
    this.primary = primary;
    this.action = action;
  }
}

@ComponentV2
export struct ArticleSwipeBar {
  @Require @Param article: Article;
  /** 是否给「分享」直达块：首页 true；订阅源详情列表 false（该页还没有分享面板，块直接不渲染）。 */
  @Param showShare: boolean = true;
  /** 「更多」里是否给「只看该源」：首页 true；订阅源详情列表 false（已是单源视图）。 */
  @Param showScopeFeed: boolean = true;
  /** 分享要 UIAbilityContext + ShareViewModel + 宿主的半模态，交给宿主；其余动作这里直接落地。 */
  @Event onShare: (article: Article) => void = () => {
  };

  /** 一个直达块：图标在上、文案在下，整块铺满行高。 */
  @Builder
  Pill(spec: SwipePillSpec) {
    Column({ space: $r('app.float.space_xs') }) {
      SymbolGlyph(spec.icon)
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_on_brand')])
      Text(spec.label)
        .fontSize($r('app.float.swipe_label_font'))
        .fontColor($r('app.color.hm_on_brand'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
    }
    .width($r('app.float.swipe_action_width'))
    .height('100%')
    .flexShrink(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: $r('app.float.space_xs'), right: $r('app.float.space_xs') })
    .backgroundColor(spec.primary ? themePalette.fill() : $r('app.color.hm_text_secondary'))
    .borderRadius($r('app.float.radius_menu_item'))
    .accessibilityText(spec.label)
    .onClick(() => {
      spec.action();
    })
  }

  /** 「更多」块：挂在同一个 Pill 外观上，额外挂下拉菜单（菜单内容在展开时现算）。 */
  @Builder
  MorePill() {
    Column({ space: $r('app.float.space_xs') }) {
      SymbolGlyph($r('sys.symbol.more'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_on_brand')])
      Text($r('app.string.action_more'))
        .fontSize($r('app.float.swipe_label_font'))
        .fontColor($r('app.color.hm_on_brand'))
        .maxLines(1)
        .textAlign(TextAlign.Center)
    }
    .width($r('app.float.swipe_action_width'))
    .height('100%')
    .flexShrink(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: $r('app.float.space_xs'), right: $r('app.float.space_xs') })
    .backgroundColor($r('app.color.hm_text_secondary'))
    .borderRadius($r('app.float.radius_menu_item'))
    .accessibilityText($r('app.string.action_more'))
    .bindMenu(this.OverflowMenu(), MaterialController.menuOptions({}, appSettings.immersiveOn))
  }

  /** 「更多」菜单：交给 AppMenu 渲染（圆角卡片 / 48vp 行高，与全工程菜单一致）。 */
  @Builder
  OverflowMenu() {
    AppMenu(this.overflowMenuSpec());
  }

  /**
   * 菜单规格：每次展开现算，读到最新的离线态 / 页面能力开关。
   * 宽度用 menu_width_wide(260vp)：默认 220vp 会把「下载此文章供离线阅读」截成省略号。
   */
  private overflowMenuSpec(): MenuSpec {
    const ids: SwipeOverflowId[] = swipeOverflowIds(this.article.offlineState, this.showScopeFeed);
    const items: MenuItemSpec[] = [];
    for (let i = 0; i < ids.length; i += 1) {
      items.push(this.overflowItem(ids[i]));
    }
    return new MenuSpec([new MenuSectionSpec(items)], $r('app.float.menu_width_wide'));
  }

  /** 一个菜单条目：文案 / 图标 / 危险色与阅读页溢出菜单同口径（分享是直达块，不在菜单里）。 */
  private overflowItem(id: SwipeOverflowId): MenuItemSpec {
    if (id === SwipeOverflowId.DOWNLOAD) {
      return new MenuItemSpec('offline_download', $r('app.string.offline_single_download'), (): void => {
        this.downloadOffline(false);
      }).withIcon($r('sys.symbol.arrow_down'));
    }
    if (id === SwipeOverflowId.RETRY) {
      return new MenuItemSpec('offline_retry', $r('app.string.offline_single_retry'), (): void => {
        this.downloadOffline(true);
      }).withIcon($r('sys.symbol.arrow_clockwise'));
    }
    if (id === SwipeOverflowId.CLEAR_OFFLINE) {
      return new MenuItemSpec('offline_clear', $r('app.string.offline_single_clear'), (): void => {
        this.clearOffline();
      }).withIcon($r('sys.symbol.trash'))
        .markDanger();
    }
    return new MenuItemSpec('scope_feed', $r('app.string.action_scope_feed'), (): void => {
      feedViewModel.scopeToFeedById(this.article.feedId);
    }).withIcon($r('sys.symbol.folder'));
  }

  /** 离线下载 / 重试（retry=true 时清掉已缓存的正文重新抓）。 */
  private downloadOffline(retry: boolean): void {
    feedViewModel.downloadArticleOffline(this.article.id, retry).then((state: string) => {
      ToastUtil.show(this.getUIContext(), state === 'full' ? $r('app.string.offline_full') :
        (state === 'none' ? $r('app.string.offline_single_failed') : $r('app.string.offline_partial')));
    }).catch(() => {
      ToastUtil.show(this.getUIContext(), $r('app.string.offline_single_failed'));
    });
  }

  /** 清除该文章的离线副本。 */
  private clearOffline(): void {
    feedViewModel.clearArticleOffline(this.article.id).then((ok: boolean) => {
      ToastUtil.show(this.getUIContext(), ok ? $r('app.string.offline_single_cleared') :
        $r('app.string.offline_single_failed'));
    }).catch(() => {
      ToastUtil.show(this.getUIContext(), $r('app.string.offline_single_failed'));
    });
  }

  build() {
    Row({ space: $r('app.float.space_s') }) {
      // 分享：一步直达（原先要「左滑 → 更多 → 分享」两步）。收藏不在这里 —— 行内星标已经覆盖。
      if (this.showShare) {
        this.Pill(new SwipePillSpec(
          $r('sys.symbol.share'),
          $r('app.string.action_share'),
          true,
          (): void => {
            this.onShare(this.article);
          }))
      }
      // 稍后读：行内只有「已稍后读」的状态图标、没有点击入口，与收藏不重复。
      this.Pill(new SwipePillSpec(
        this.article.saved ? $r('sys.symbol.bookmark_fill') : $r('sys.symbol.bookmark'),
        this.article.saved ? $r('app.string.action_unsave') : $r('app.string.action_save'),
        true,
        (): void => {
          feedViewModel.toggleSaved(this.article.id);
        }))
      // 已读：已读的文章给「空心圈 + 标为未读」，未读的给「对勾 + 标为已读」。
      this.Pill(new SwipePillSpec(
        this.article.read ? $r('sys.symbol.circle') : $r('sys.symbol.checkmark_circle'),
        this.article.read ? $r('app.string.action_mark_unread') : $r('app.string.action_mark_read'),
        true,
        (): void => {
          feedViewModel.toggleRead(this.article.id);
        }))
      // 更多：离线动作（下载 / 重试 / 清除）与「只看该源」收在这里。
      this.MorePill()
    }
    .height('100%')
    .padding({ left: $r('app.float.space_s') })
  }
}
