/*
 * FilterSegmentBar.ets — 阅读页签的「全部 / 未读 / 收藏」筛选分段控件 + 全部已读。
 *
 * 位置：挂在 HdsNavigation 标题栏的 bottomBuilder 上（不是内容区）——沉浸光感是区域级能力，
 * 只有 Navigation/NavDestination 标题栏与横向 Tabs 底部 TabBar 里组件才真正吃到系统材质，
 * 放内容区只会打 "Material inactive: out of scope"。因此这里用组件级 backgroundSystemMaterial
 * 拿到 HDS 沉浸光感，材质不可用时再用「背板模糊 + 半透明色」兜底成玻璃面。
 * 逻辑全在 FeedViewModel，这里只读状态、上报点击。
 */

import { ColorMetrics, SegmentButtonV2Items, TabSegmentButtonV2 } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { appSettings } from '../model/AppSettings';
import { MaterialController } from '../service/MaterialController';
import { ArticleFilter } from '../common/constants/RssConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'FilterSegmentBar';

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
export struct FilterSegmentBar {
  /** 筛选分段控件的选项（全部 / 未读 / 收藏）。 */
  private filterItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: $r('app.string.filter_all') },
    { text: $r('app.string.filter_unread') },
    { text: $r('app.string.filter_starred') }
  ]);

  /**
   * 分段按钮的文本配色。
   * `ColorMetrics.resourceColor` 标注了可能抛异常，ArkTS 要求调用点必须 catch；
   * 失败时返回 undefined 退回组件默认样式。
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

  build() {
    Row({ space: $r('app.float.space_s') }) {
      // 分段控件不支持通用属性，会吃掉所在区域的「最大可用宽度」，直接放进 Row 会把右侧按钮挤成 0 宽。
      // 因此套一层 layoutWeight(1) 的容器：它按固定尺寸的按钮量完后再取剩余宽度，按钮宽度得以保留。
      Row() {
        TabSegmentButtonV2({
          items: this.filterItems,
          selectedIndex: filterIndexOf(feedViewModel.filter),
          onItemClicked: (index: number) => {
            feedViewModel.setFilter(filterAt(index));
          },
          // 特殊系统资源值：未选中态跟随主题文字色。
          itemFontColor: this.safeColor($r('sys.color.font_primary')),
          itemSelectedFontColor: this.safeColor(Color.Black),
          // 沉浸光感：优先组件级系统材质（标题栏属生效区域，会真渲染）；不支持时退回模糊兜底。
          backgroundSystemMaterial: MaterialController.controlMaterial(appSettings.immersiveOn),
          buttonBackgroundColor: appSettings.immersiveOn
            ? this.safeColor($r('app.color.hm_glass_scrim'))
            : undefined,
          buttonBackgroundBlurStyle: appSettings.immersiveOn ? BlurStyle.COMPONENT_THICK : undefined
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
    .height('100%')
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    .alignItems(VerticalAlign.Center)
  }
}
