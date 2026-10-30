/*
 * SettingsFeedView.ets — 「订阅与通知」二级页（纯展示 + 事件上报）。
 *
 * 内容：跨源去重、自动刷新、立即刷新、归档规则、标注库入口、新文章通知与通知设置入口、
 *       OPML 导入 / 导出（从订阅源页移来）。
 * 业务逻辑在 SettingsViewModel / FeedViewModel，这里只读状态、把操作上报。
 */

import { common } from '@kit.AbilityKit';
import {
  HdsSnackBar,
  SnackBarIconOptions,
  SnackBarMessageOptions,
  SnackBarOperationOptions,
  SnackBarStyleOptions,
  SnackBarOperationType
} from '@kit.UIDesignKit';
import {
  ARCHIVE_OPTIONS,
  AUTO_REFRESH_OPTIONS
} from '../../model/SettingsOptions';
import { settingsViewModel } from '../../viewmodel/SettingsViewModel';
import { feedViewModel } from '../../viewmodel/FeedViewModel';
import { articleStore } from '../../service/ArticleStore';
import { opmlService } from '../../service/OpmlService';
import { OpmlEntry, parseOpml } from '../../service/OpmlCodec';
import { RouterConstants } from '../../common/constants/RouterConstants';
import { safeArea } from '../../service/SafeAreaController';
import { DateUtil } from '../../common/utils/DateUtil';
import { ToastUtil } from '../../common/utils/ToastUtil';
import {
  ActionSettingRow,
  NavSettingRow,
  OptionSelectRow,
  SettingField,
  SettingIconTitle,
  SettingsSectionTitle,
  SwitchSettingRow
} from './SettingsRows';

@ComponentV2
export struct SettingsFeedView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  /** 标注条数（进页面时读一次，够用于入口行的展示）。 */
  @Local highlightCount: number = 0;

  aboutToAppear(): void {
    this.reloadHighlightCount();
  }

  private async reloadHighlightCount(): Promise<void> {
    this.highlightCount = await articleStore.countHighlights();
  }

  private hostContext(): common.UIAbilityContext {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    return context as common.UIAbilityContext;
  }

  /** 开启通知前先申请系统授权；失败则提示并保持关闭。 */
  private async toggleNotify(value: boolean): Promise<void> {
    const granted: boolean = await settingsViewModel.setNotifyNewArticles(value, this.hostContext());
    if (value && !granted) {
      ToastUtil.show(this.getUIContext(), $r('app.string.toast_notify_denied'));
    }
  }

  /** 导入 OPML：选文件 → 解析 → 去重入库并抓取。 */
  private async importOpml(): Promise<void> {
    const text: string = await opmlService.importFromFile(this.hostContext());
    if (text.length === 0) {
      return;
    }
    const entries: OpmlEntry[] = parseOpml(text);
    if (entries.length === 0) {
      ToastUtil.show(this.getUIContext(), $r('app.string.subs_import_empty'));
      return;
    }
    const added: number = await feedViewModel.importFeeds(entries);
    ToastUtil.show(this.getUIContext(), added > 0
      ? $r('app.string.subs_import_result', added)
      : $r('app.string.subs_import_duplicate'));
  }

  /** 导出 OPML：把当前订阅写进用户选定的文件。 */
  private async exportOpml(): Promise<void> {
    if (feedViewModel.feeds.length === 0) {
      ToastUtil.show(this.getUIContext(), $r('app.string.subs_export_empty'));
      return;
    }
    const ok: boolean = await opmlService.exportToFile(this.hostContext(), feedViewModel.exportOpml());
    if (ok) {
      ToastUtil.show(this.getUIContext(), $r('app.string.subs_export_success'));
    }
  }

  /** 手动刷新：抓取全部订阅源，完成后用 SnackBar 反馈。 */
  private refreshNow(): void {
    if (feedViewModel.loading) {
      ToastUtil.show(this.getUIContext(), $r('app.string.toast_refreshing'));
      return;
    }
    feedViewModel.refreshAll(true).then(() => {
      const bar: HdsSnackBar = new HdsSnackBar(this.getUIContext());
      const icon: SnackBarIconOptions = { icon: $r('sys.symbol.checkmark_circle') };
      const message: SnackBarMessageOptions = { title: $r('app.string.snack_refreshed') };
      const operation: SnackBarOperationOptions = {
        operationType: SnackBarOperationType.CLOSE_BUTTON_ONLY,
        closeButtonAccessibilityText: $r('app.string.snack_dismiss')
      };
      bar.show(icon, message, operation, { duration: 2000 } as SnackBarStyleOptions);
    });
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // 透明标题栏占位：内容可以穿过标题栏下方。
        Row().width('100%').height(safeArea.contentTopInsetVp)

        SettingsSectionTitle({ title: $r('app.string.section_feed') })
        Column() {
          // 跨源去重总开关：只影响新入库文章是否合并，已有合并组保持现状。
          SwitchSettingRow({
            icon: $r('sys.symbol.doc_text'),
            title: $r('app.string.dedupe_settings_title'),
            field: SettingField.DEDUPE,
            onToggle: (value: boolean) => {
              settingsViewModel.setDedupeEnabled(value);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.arrow_clockwise'),
            title: $r('app.string.row_auto_refresh'),
            choice: AUTO_REFRESH_OPTIONS,
            field: SettingField.AUTO_REFRESH,
            onPick: (id: string) => {
              settingsViewModel.setAutoRefresh(id, this.hostContext());
            }
          })
          Divider().color($r('app.color.hm_divider'))
          // 立即刷新：右侧显示上次同步时间。
          Row() {
            SettingIconTitle({ icon: $r('sys.symbol.arrow_clockwise'), title: $r('app.string.row_refresh_now') })
            Blank()
            Text(feedViewModel.lastUpdated > 0
              ? $r('app.string.home_last_sync', DateUtil.clock(feedViewModel.lastUpdated))
              : $r('app.string.home_never_synced'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
          }
          .width('100%')
          .height($r('app.float.row_height'))
          .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
          .onClick(() => {
            this.refreshNow();
          })
          Divider().color($r('app.color.hm_divider'))
          NavSettingRow({
            icon: $r('sys.symbol.paintpalette'),
            title: $r('app.string.hl_library_title'),
            detail: $r('app.string.hl_panel_title', this.highlightCount),
            onOpen: () => {
              this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_HIGHLIGHTS, ''));
            }
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.externaldrive'),
            title: $r('app.string.row_archive_rule'),
            choice: ARCHIVE_OPTIONS,
            field: SettingField.ARCHIVE_RULE,
            onPick: (id: string) => {
              settingsViewModel.setArchiveRule(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          SwitchSettingRow({
            icon: $r('sys.symbol.bell'),
            title: $r('app.string.row_notify_new'),
            field: SettingField.NOTIFY_NEW,
            onToggle: (value: boolean) => {
              this.toggleNotify(value);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          // 免打扰 / 每日摘要 / 关键词 / 授权状态都收在独立页面。
          NavSettingRow({
            icon: $r('sys.symbol.bell'),
            title: $r('app.string.notify_settings_title'),
            onOpen: () => {
              this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_NOTIFY_SETTINGS, ''));
            }
          })
          Divider().color($r('app.color.hm_divider'))
          // OPML 导入 / 导出：从订阅源页移来，统一收在设置里；都走系统文档选择器，无需存储权限。
          ActionSettingRow({
            icon: $r('sys.symbol.doc_text'),
            title: $r('app.string.subs_import_opml'),
            onAction: () => {
              this.importOpml();
            }
          })
          Divider().color($r('app.color.hm_divider'))
          ActionSettingRow({
            icon: $r('sys.symbol.doc_text'),
            title: $r('app.string.subs_export_opml'),
            onAction: () => {
              this.exportOpml();
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        Text($r('app.string.dedupe_switch_desc'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })

        // 底部预留：避让系统导航条。
        Blank().height(safeArea.contentBottomInsetVp)
      }
      .width('100%')
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    // Scroll 默认把「内容比视口短」的内容整体居中，会让首屏顶部多出一条空白；
    // 这里固定从顶部开始排。
    .align(Alignment.TopStart)
    .clip(false)
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
