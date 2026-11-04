/*
 * SyncView.ets — 「云同步（实验）」二级页（纯状态管理 V2）。
 *
 * 第一批只接本机 Mock 后端：开关、目标说明、上次同步 / 待推送 / 已同步条目、
 * 立即同步与重置模拟远端。接真实服务端时这里只需换后端名称与说明文案。
 *
 * 页面状态用 @Local 承载，数据读写都在 SyncService。
 */

import { common } from '@kit.AbilityKit';
import { appSettings } from '../model/AppSettings';
import { SyncConflict, SyncKinds, SyncSummary } from '../model/Sync';
import { DateUtil } from '../common/utils/DateUtil';
import { safeArea } from '../service/SafeAreaController';
import { MaterialController } from '../service/MaterialController';
import { SyncStatus, syncService } from '../service/SyncService';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import {
  HdsSnackBar,
  SnackBarIconOptions,
  SnackBarMessageOptions,
  SnackBarOperationOptions,
  SnackBarOperationType,
  SnackBarStyleOptions
} from '@kit.UIDesignKit';
import { SettingIconTitle, SettingsSectionTitle } from './settings/SettingsRows';
import { themePalette } from '../model/ThemePalette';
import { SyncConflictSummary } from './SyncConflictSummary';

@ComponentV2
export struct SyncView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  @Local syncOn: boolean = false;
  @Local wifiOnly: boolean = true;
  @Local cloudBackend: boolean = false;
  @Local conflicts: number = 0;
  @Local lastSyncAt: number = 0;
  @Local pending: number = 0;
  @Local records: number = 0;
  @Local backend: string = '';
  @Local syncing: boolean = false;
  /** 选了云同步目标时：最近一次登记或手动拉取是否成功。 */
  @Local cloudAvailable: boolean = true;
  @Local cloudReason: string = '';
  @Local cloudErrorCode: number = 0;
  /** 上次同步自动合并的记录概要（最多 CONFLICT_DETAILS 条）。 */
  @Local conflictItems: SyncConflict[] = [];
  private refreshToken: number = 0;

  /** 状态变化回调：自动同步 / 云端变更完成后，页面上的时间与条数实时刷新。 */
  private onStatusChanged: () => void = () => {
    this.refresh();
  };

  aboutToAppear(): void {
    this.refresh();
    syncService.subscribeStatus(this.onStatusChanged);
  }

  aboutToDisappear(): void {
    this.refreshToken += 1;
    syncService.unsubscribeStatus(this.onStatusChanged);
  }

  private hostContext(): common.Context | undefined {
    return this.getUIContext().getHostContext();
  }

  /** 进入页面 / 每次操作后刷新状态。 */
  private refresh(): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      return;
    }
    const token: number = ++this.refreshToken;
    syncService.status(context).then((status: SyncStatus) => {
      if (token !== this.refreshToken) {
        return;
      }
      this.syncOn = status.enabled;
      this.wifiOnly = status.wifiOnly;
      this.cloudBackend = status.backend === 'Cloud';
      this.conflicts = status.conflicts;
      this.lastSyncAt = status.lastSyncAt;
      this.pending = status.pending;
      this.records = status.records;
      this.backend = status.backend;
      this.cloudAvailable = status.cloudAvailable;
      this.cloudReason = status.cloudReason;
      this.cloudErrorCode = status.cloudErrorCode;
      this.conflictItems = status.conflictItems;
    });
  }

  /** 只显示能由系统错误码确认的具体原因；其余给排查步骤。 */
  private cloudUnavailableText(): ResourceStr {
    if (this.cloudReason === 'unsupported') {
      return $r('app.string.sync_cloud_unavailable_unsupported');
    }
    if (this.cloudReason === 'storeFailed') {
      return $r('app.string.sync_cloud_unavailable_store');
    }
    if (this.cloudReason === 'tableTypeMismatch') {
      return $r('app.string.sync_cloud_unavailable_table_type');
    }
    if (this.cloudReason === 'cloudDisabled') {
      return $r('app.string.sync_cloud_unavailable_cloud_disabled');
    }
    if (this.cloudReason === 'networkFailed') {
      return $r('app.string.sync_cloud_unavailable_network');
    }
    if (this.cloudReason === 'wifiRequired') {
      return $r('app.string.sync_cloud_unavailable_wifi');
    }
    if (this.cloudReason === 'syncFailed') {
      return $r('app.string.sync_cloud_unavailable_sync');
    }
    return $r('app.string.sync_cloud_unavailable');
  }

  private lastSyncText(): ResourceStr {
    return this.lastSyncAt > 0
      ? DateUtil.format(this.lastSyncAt)
      : $r('app.string.remote_status_never');
  }

  private backendText(): ResourceStr {
    if (this.cloudBackend) {
      return $r('app.string.sync_backend_cloud');
    }
    return this.backend.length > 0 ? this.backend : $r('app.string.sync_backend_mock');
  }

  private showSnack(message: ResourceStr): void {
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

  private toggle(value: boolean): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      return;
    }
    // 关闭同步只改开关，不动本地数据；重新打开后下一次同步继续合并。
    this.syncOn = value;
    syncService.setEnabled(context, value).then(() => {
      this.refresh();
    });
  }

  private toggleCloud(value: boolean): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      return;
    }
    // 切到云端只是换同步目标：本地数据与同步副本都保留，随时可以切回本机模拟。
    this.cloudBackend = value;
    syncService.setCloudBackend(context, value).then(() => {
      this.refresh();
    });
  }

  private toggleWifiOnly(value: boolean): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      return;
    }
    // 应用自动触发和系统端云传输都遵守此网络策略。
    this.wifiOnly = value;
    syncService.setWifiOnly(context, value).then(() => {
      this.refresh();
    });
  }

  private syncNow(): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined || this.syncing) {
      return;
    }
    this.syncing = true;
    syncService.syncNow(context).then((summary: SyncSummary) => {
      this.syncing = false;
      if (summary.error.length === 0) {
        // 同步可能带来新订阅 / 状态变化：刷新首页列表。
        feedViewModel.reloadAfterBackup(context).then(() => {
          this.showSnack($r('app.string.sync_done', summary.pushed, summary.pulled));
          this.refresh();
        });
      } else {
        if (summary.error === 'cloud unavailable' && this.cloudBackend) {
          syncService.status(context).then((status: SyncStatus) => {
            this.cloudAvailable = status.cloudAvailable;
            this.cloudReason = status.cloudReason;
            this.cloudErrorCode = status.cloudErrorCode;
            this.showSnack(this.cloudUnavailableText());
            this.refresh();
          }).catch(() => {
            this.showSnack($r('app.string.sync_cloud_unavailable'));
            this.refresh();
          });
        } else {
          this.showSnack($r('app.string.sync_failed', summary.error));
          this.refresh();
        }
      }
    });
  }

  private confirmReset(): void {
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const confirmButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_confirm'),
      fontColor: themePalette.accent(),
      action: () => {
        const context: common.Context | undefined = this.hostContext();
        if (context === undefined) {
          return;
        }
        syncService.resetRemote(context).then(() => {
          this.refresh();
        });
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.sync_reset_title'),
      message: $r('app.string.sync_reset_body'),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: confirmButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // 透明标题栏占位：内容可以穿过标题栏下方。
        Row().width('100%').height(safeArea.contentTopInsetVp)

        SettingsSectionTitle({ title: $r('app.string.sync_entry_title') })
        Column() {
          Row() {
            Row() {
              SettingIconTitle({ icon: $r('sys.symbol.arrow_clockwise'),
                title: $r('app.string.sync_row_enable') })
            }
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.syncOn })
              .selectedColor(themePalette.fill())
              .onChange((value: boolean) => {
                this.toggle(value);
              })
          }
          .width('100%')
          .height($r('app.float.row_height'))
          .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })

          Divider().color($r('app.color.hm_divider'))

          Row() {
            Row() {
              SettingIconTitle({ icon: $r('sys.symbol.icloud'),
                title: $r('app.string.sync_row_cloud') })
            }
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.cloudBackend })
              .selectedColor(themePalette.fill())
              .onChange((value: boolean) => {
                this.toggleCloud(value);
              })
          }
          .width('100%')
          .height($r('app.float.row_height'))
          .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })

          Divider().color($r('app.color.hm_divider'))

          Row() {
            Row() {
              SettingIconTitle({ icon: $r('sys.symbol.wifi'),
                title: $r('app.string.sync_row_wifi_only') })
            }
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.wifiOnly })
              .selectedColor(themePalette.fill())
              .onChange((value: boolean) => {
                this.toggleWifiOnly(value);
              })
          }
          .width('100%')
          .height($r('app.float.row_height'))
          .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })

          Divider().color($r('app.color.hm_divider'))

          Row() {
            Row() {
              SettingIconTitle({ icon: $r('sys.symbol.arrow_clockwise'),
                title: $r('app.string.remote_sync_now') })
            }
            .layoutWeight(1)
            Text(this.syncing ? $r('app.string.remote_syncing') : this.lastSyncText())
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .maxLines(1)
          }
          .width('100%')
          .height($r('app.float.row_height'))
          .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
          .onClick(() => {
            this.syncNow();
          })

          Divider().color($r('app.color.hm_divider'))

          Row() {
            Row() {
              SettingIconTitle({ icon: $r('sys.symbol.link'),
                title: $r('app.string.sync_row_backend') })
            }
            .layoutWeight(1)
            Text(this.backendText())
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .height($r('app.float.row_height'))
          .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })

          Divider().color($r('app.color.hm_divider'))

          Row() {
            Row() {
              SettingIconTitle({ icon: $r('sys.symbol.icloud'),
                title: $r('app.string.sync_row_pending') })
            }
            .layoutWeight(1)
            Text(this.pending.toString())
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
          }
          .width('100%')
          .height($r('app.float.row_height'))
          .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })

          Divider().color($r('app.color.hm_divider'))

          Row() {
            Row() {
              SettingIconTitle({ icon: $r('sys.symbol.checkmark_circle'),
                title: $r('app.string.sync_row_records') })
            }
            .layoutWeight(1)
            Text(this.records.toString())
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
          }
          .width('100%')
          .height($r('app.float.row_height'))
          .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })

          Divider().color($r('app.color.hm_divider'))

          Row() {
            Row() {
              SettingIconTitle({ icon: $r('sys.symbol.trash'), title: $r('app.string.sync_reset') })
            }
            .layoutWeight(1)
          }
          .width('100%')
          .height($r('app.float.row_height'))
          .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
          .onClick(() => {
            this.confirmReset();
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        // 选了端云但能力不可用：说清原因，别让用户以为「点了同步就是同步了」。
        if (this.cloudBackend && !this.cloudAvailable) {
          Text(this.cloudUnavailableText())
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })
          if (this.cloudErrorCode > 0) {
            Text($r('app.string.sync_cloud_error_code', this.cloudErrorCode))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .width('100%')
              .margin({ top: $r('app.float.space_xs'), left: $r('app.float.space_xs') })
          }
        }

        SyncConflictSummary({ conflicts: this.conflicts, items: this.conflictItems })

        Text(this.cloudBackend ? $r('app.string.sync_aux_cloud') : $r('app.string.sync_aux_mock'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })

        // 底部预留：避让系统导航条。
        Blank().height(safeArea.contentBottomInsetVp)
      }
      .width('100%')
      .padding({
        left: $r('app.float.space_l'),
        right: $r('app.float.space_l')
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
    .clip(false)
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
