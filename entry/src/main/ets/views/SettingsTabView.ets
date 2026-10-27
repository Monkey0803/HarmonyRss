/*
 * SettingsTabView.ets — 设置页签首页（纯索引，纯状态管理 V2）。
 *
 * 结构：5 个二级页入口（外观与语言 / 材质与动效 / 阅读与列表 / 订阅与通知 / 系统与隐私）
 *       + 「存储与备份」卡片（存储与保留、备份与恢复、清理正文缓存）。
 * 具体设置项都在 views/settings/ 下的二级页里，首页只负责「找到」与高频的清理动作。
 *
 * 关键约束：入口行的当前值（detail）读的是 appSettings 的 @Trace 字段，
 * 因此在二级页改完返回时，这里会自动刷新。
 */

import {
  HdsSnackBar,
  SnackBarIconOptions,
  SnackBarMessageOptions,
  SnackBarOperationOptions,
  SnackBarStyleOptions,
  SnackBarOperationType
} from '@kit.UIDesignKit';
import { appSettings } from '../model/AppSettings';
import {
  AUTO_REFRESH_OPTIONS,
  MATERIAL_LEVEL_OPTIONS,
  READER_FONT_OPTIONS,
  THEME_OPTIONS
} from '../model/SettingsOptions';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { safeArea } from '../service/SafeAreaController';
import { MaterialController } from '../service/MaterialController';
import { antiPeep } from '../service/AntiPeep';
import { RouterConstants } from '../common/constants/RouterConstants';
import { ActionSettingRow, NavSettingRow, SettingsSectionTitle } from './settings/SettingsRows';

@ComponentV2
export struct SettingsTabView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  /** 进设置页时刷新一次正文缓存占用（存储区展示用）。 */
  aboutToAppear(): void {
    feedViewModel.refreshCacheStats();
  }

  /** 缓存占用文案：条数 + 粗略体积（KB/MB）。 */
  private cacheSummary(): ResourceStr {
    const count: number = feedViewModel.cachedArticles;
    const kb: number = Math.round(feedViewModel.cachedChars / 1024);
    const size: string = kb < 1024 ? (kb.toString() + 'KB') : ((kb / 1024).toFixed(1) + 'MB');
    return $r('app.string.cache_summary', count, size);
  }

  /** 清理正文缓存（保留收藏）：二次确认后执行，并即时刷新占用。 */
  private confirmClearCache(): void {
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const confirmButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_confirm'),
      fontColor: $r('app.color.hm_brand'),
      action: () => {
        feedViewModel.clearCachedContent().then((cleared: number) => {
          this.showCacheSnack($r('app.string.snack_cache_cleared', cleared));
        });
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.dialog_clear_cache_title'),
      message: $r('app.string.dialog_clear_cache_message'),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: confirmButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  /** 清理结果提示。 */
  private showCacheSnack(message: ResourceStr): void {
    const bar: HdsSnackBar = new HdsSnackBar(this.getUIContext());
    const icon: SnackBarIconOptions = { icon: $r('sys.symbol.checkmark_circle') };
    const text: SnackBarMessageOptions = { title: message };
    const operation: SnackBarOperationOptions = {
      operationType: SnackBarOperationType.CLOSE_BUTTON_ONLY,
      closeButtonAccessibilityText: $r('app.string.snack_dismiss')
    };
    const style: SnackBarStyleOptions = { duration: 3000 };
    bar.show(icon, text, operation, style);
  }

  private openPage(page: string): void {
    this.navPathStack.pushPath(new NavPathInfo(page, ''));
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // 透明标题栏占位：首屏顶部预留「状态栏 + 标题栏」高度，滚动时随内容上移，内容即可穿过标题栏下方。
        Row().width('100%').height(safeArea.contentTopInsetVp)

        // 索引卡片：每行一个二级页入口，右侧带当前值。
        Column() {
          NavSettingRow({
            icon: $r('sys.symbol.paintpalette'),
            title: $r('app.string.settings_entry_look'),
            detail: THEME_OPTIONS.labelOf(appSettings.themeMode),
            onOpen: () => {
              this.openPage(RouterConstants.PAGE_SETTINGS_LOOK);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          NavSettingRow({
            icon: $r('sys.symbol.rays'),
            title: $r('app.string.settings_entry_material'),
            detail: MATERIAL_LEVEL_OPTIONS.labelOf(appSettings.materialLevel),
            onOpen: () => {
              this.openPage(RouterConstants.PAGE_SETTINGS_MATERIAL);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          NavSettingRow({
            icon: $r('sys.symbol.textformat'),
            title: $r('app.string.settings_entry_reading'),
            detail: READER_FONT_OPTIONS.labelOf(appSettings.readerFont),
            onOpen: () => {
              this.openPage(RouterConstants.PAGE_SETTINGS_READING);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          NavSettingRow({
            icon: $r('sys.symbol.arrow_clockwise'),
            title: $r('app.string.settings_entry_feed'),
            detail: AUTO_REFRESH_OPTIONS.labelOf(appSettings.autoRefresh),
            onOpen: () => {
              this.openPage(RouterConstants.PAGE_SETTINGS_FEED);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          NavSettingRow({
            icon: $r('sys.symbol.lock'),
            title: $r('app.string.settings_entry_system'),
            onOpen: () => {
              this.openPage(RouterConstants.PAGE_SETTINGS_SYSTEM);
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))
        .margin({ top: $r('app.float.space_l') })

        SettingsSectionTitle({ title: $r('app.string.settings_entry_storage') })
        Column() {
          // 保留策略 / 存储占用 / 回收站 / 索引重建都在独立页面。
          NavSettingRow({
            icon: $r('sys.symbol.externaldrive'),
            title: $r('app.string.storage_title'),
            onOpen: () => {
              this.openPage(RouterConstants.PAGE_STORAGE);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          // 备份与迁移：导出 JSON / 合并导入 / 本地快照都在独立页面里。
          NavSettingRow({
            icon: $r('sys.symbol.externaldrive'),
            title: $r('app.string.backup_entry'),
            onOpen: () => {
              this.openPage(RouterConstants.PAGE_BACKUP);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          ActionSettingRow({
            icon: $r('sys.symbol.externaldrive'),
            title: $r('app.string.row_reader_cache'),
            detail: this.cacheSummary(),
            onAction: () => {
              this.confirmClearCache();
            }
          })
          Text($r('app.string.aux_reader_cache'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding({
              left: $r('app.float.space_m'),
              right: $r('app.float.space_m'),
              bottom: $r('app.float.space_m')
            })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))
        .alignItems(HorizontalAlign.Start)

        if (!antiPeep.supported) {
          Text($r('app.string.aux_antipeep_unsupported'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })
        }

        // 底部预留：避让悬浮页签栏与系统导航条。
        Blank().height(safeArea.contentBottomInsetVp)
      }
      .width('100%')
      // 首屏位置由 HDS 的标题栏安全区自动排定，这里只留左右间距。
      .padding({
        left: $r('app.float.space_l'),
        right: $r('app.float.space_l')
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    // Scroll 默认会把「内容比视口短」的内容整体居中，首屏顶部会多出一条空白；固定从顶部排。
    .align(Alignment.TopStart)
    // 内容穿透标题栏：超出滚动区范围的部分不裁剪。
    .clip(false)
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
