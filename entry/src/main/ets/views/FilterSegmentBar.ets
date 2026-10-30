/*
 * FilterSegmentBar.ets — 阅读页签的「全部 / 未读 / 收藏 / 稍后读 / 归档」筛选条 + 全部已读。
 *
 * 位置：挂在 HdsNavigation 标题栏的 bottomBuilder 上（不是内容区）——沉浸光感是区域级能力，
 * 只有 Navigation/NavDestination 标题栏与横向 Tabs 底部 TabBar 里组件才真正吃到系统材质，
 * 放内容区只会打 "Material inactive: out of scope"。因此这里用组件级 systemMaterial
 * 拿到 HDS 沉浸光感，材质不可用时再用「背板模糊 + 半透明色」兜底成玻璃面。
 *
 * 为什么不用 HDS 的 TabSegmentButtonV2：它按「按钮个数平均分配可用宽度」且不支持通用属性，
 * 多语言下德 / 法 / 西文案会被截成「Un…」「Ma…」，无法完整显示。这里改成自绘胶囊 + 横向滚动：
 * 每项按文字宽度排布，超出时整条可横向滑动，切换逻辑与视觉层级保持不变。
 *
 * 逻辑全在 FeedViewModel，这里只读状态、上报点击。
 *
 * 用全局 @Builder 而不是自定义组件：纯展示、无生命周期需求
 * （CodeLinter @performance/avoid-overusing-custom-component-check）。
 * Dialog 需要 UIContext，故由调用方传入。
 */

import { UIContext } from '@kit.ArkUI';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { appSettings } from '../model/AppSettings';
import { MaterialController } from '../service/MaterialController';
import { ArticleFilter } from '../common/constants/RssConstants';

/** 分段的顺序：新增筛选项时同步补 labelOf()。 */
const FILTER_ORDER: string[] = [
  ArticleFilter.ALL,
  ArticleFilter.UNREAD,
  ArticleFilter.STARRED,
  ArticleFilter.SAVED,
  ArticleFilter.ARCHIVED
];

/** 筛选值 → 文案。 */
function labelOf(filter: string): ResourceStr {
  switch (filter) {
    case ArticleFilter.UNREAD:
      return $r('app.string.filter_unread');
    case ArticleFilter.STARRED:
      return $r('app.string.filter_starred');
    case ArticleFilter.SAVED:
      return $r('app.string.filter_saved');
    case ArticleFilter.ARCHIVED:
      return $r('app.string.filter_archived');
    default:
      return $r('app.string.filter_all');
  }
}

/** 全部已读前确认。 */
function confirmMarkAllRead(ui: UIContext): void {
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
  ui.showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
}

/** 筛选胶囊里的选项：按文字宽度排布，整条横向可滚动。 */
@Builder
function FilterChips() {
  Scroll() {
    Row({ space: $r('app.float.space_xxs') }) {
      ForEach(FILTER_ORDER, (filter: string) => {
        Text(labelOf(filter))
          .fontSize($r('app.float.font_size_caption'))
          .fontWeight(feedViewModel.filter === filter ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(feedViewModel.filter === filter
            ? $r('app.color.hm_brand')
            : $r('app.color.hm_text_primary'))
          .maxLines(1)
          .height('100%')
          .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
          .borderRadius($r('app.float.radius_chip'))
          .backgroundColor(feedViewModel.filter === filter
            ? $r('app.color.hm_card_background')
            : $r('app.color.hm_page_transparent'))
          .onClick(() => {
            feedViewModel.setFilter(filter);
          })
      }, (filter: string) => filter)
    }
    .height('100%')
    .padding({ left: $r('app.float.space_xxs'), right: $r('app.float.space_xxs') })
  }
  .scrollable(ScrollDirection.Horizontal)
  .scrollBar(BarState.Off)
  .width('100%')
  .height('100%')
  .align(Alignment.Start)
}

/** 有沉浸光感能力时的胶囊：材质由系统渲染，底色必须留透明。 */
@Builder
function CapsuleWithMaterial() {
  Row() {
    FilterChips()
  }
  .layoutWeight(1)
  .height($r('app.float.value_chip_height'))
  .borderRadius($r('app.float.radius_chip'))
  .clip(true)
  .systemMaterial(MaterialController.titleMaterial(appSettings.immersiveOn))
  .alignItems(VerticalAlign.Center)
}

/** 材质不可用时的兜底胶囊：半透明底 + 背板模糊。 */
@Builder
function CapsuleFallback() {
  Row() {
    FilterChips()
  }
  .layoutWeight(1)
  .height($r('app.float.value_chip_height'))
  .borderRadius($r('app.float.radius_chip'))
  .clip(true)
  .backgroundColor($r('app.color.hm_glass_scrim'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  .alignItems(VerticalAlign.Center)
}

/** 「全部已读」：做成有底色的胶囊按钮（图标 + 文案），否则纯文字会被当成标签、看不出可点。 */
@Builder
function MarkAllReadButton(ui: UIContext) {
  Button({ type: ButtonType.Capsule, stateEffect: true }) {
    Row({ space: $r('app.float.space_xxs') }) {
      SymbolGlyph($r('sys.symbol.checkmark_circle'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_brand')])
      Text($r('app.string.home_mark_all_read'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_brand'))
        .maxLines(1)
    }
    .alignItems(VerticalAlign.Center)
  }
  .height($r('app.float.value_chip_height'))
  .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
  .backgroundColor($r('app.color.hm_card_background'))
  .flexShrink(0)
  .enabled(feedViewModel.unreadTotal > 0)
  .onClick(() => {
    confirmMarkAllRead(ui);
  })
}

/** 标题栏 bottomBuilder：筛选胶囊 + 全部已读。 */
@Builder
export function FilterSegmentBar(ui: UIContext) {
  Row({ space: $r('app.float.space_s') }) {
    if (MaterialController.materialRenders(appSettings.immersiveOn)) {
      CapsuleWithMaterial()
    } else {
      CapsuleFallback()
    }
    MarkAllReadButton(ui)
  }
  .width('100%')
  .height('100%')
  .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
  .alignItems(VerticalAlign.Center)
}
