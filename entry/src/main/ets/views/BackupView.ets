/*
 * BackupView.ets — 「备份与恢复」页（NavDestination 内容，纯状态管理 V2）。
 *
 * 三段内容：
 *   1) 导出：说明 + 内容清单 + 「导出备份」（系统保存面板），失败时就地显示原因；
 *   2) 导入：「同时恢复设置」开关 + 「导入备份」（系统选择面板），完成后展示合并统计；
 *   3) 自动快照：立即备份 + 快照列表（时间 / 大小），每行可恢复 / 删除（都要二次确认）。
 *
 * 页面只读 BackupViewModel 的状态、把用户操作上报给它：
 * 文件选择器、合并、快照读写都在 BackupService，导入后的列表与计数刷新也在 ViewModel 里编排。
 */

import { common } from '@kit.AbilityKit';
import { BackupSummary, SnapshotInfo } from '../model/Backup';
import { BackupError, backupViewModel } from '../viewmodel/BackupViewModel';
import { appSettings } from '../model/AppSettings';
import { MaterialController } from '../service/MaterialController';
import { safeArea } from '../service/SafeAreaController';
import { DateUtil } from '../common/utils/DateUtil';
import { ToastUtil } from '../common/utils/ToastUtil';

/** 首次进页面快照列表为空时的补读延迟（毫秒）：等启动时的自动快照把文件写完。 */
const SNAPSHOT_RETRY_MS: number = 1200;

/**
 * 统计行：标签 + 数值。
 * 单独做成 @ComponentV2：多参 @Builder 传入两个及以上参数时不随状态刷新，
 * 而导入统计会在同一次会话里被第二次导入改写。
 */
@ComponentV2
struct BackupStatRow {
  @Param label: ResourceStr = '';
  @Param value: number = 0;
  /** 失败计数用警示色。 */
  @Param danger: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
      Blank()
      Text(this.value.toString())
        .fontSize($r('app.float.font_size_caption'))
        .fontColor(this.danger ? $r('app.color.hm_danger') : $r('app.color.hm_text_primary'))
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
  }
}

/** 快照行：创建时间 + 体积 + 恢复 / 删除。 */
@ComponentV2
struct BackupSnapshotRow {
  @Param info: SnapshotInfo = new SnapshotInfo();
  /** 有长任务在跑时禁用操作，避免并发写同一批表。 */
  @Param rowEnabled: boolean = true;
  @Event onRestore: (info: SnapshotInfo) => void = () => {
  };
  @Event onDelete: (info: SnapshotInfo) => void = () => {
  };

  /** 创建时间文案（时间戳缺失时退回文件名里的日期）。 */
  private timeText(): string {
    const text: string = DateUtil.format(this.info.createdAt);
    return text.length > 0 ? text : this.info.fileName;
  }

  /** 字节 → KB / MB。 */
  private sizeText(): string {
    const bytes: number = this.info.sizeBytes;
    if (bytes <= 0) {
      return '0KB';
    }
    const kb: number = Math.ceil(bytes / 1024);
    if (kb < 1024) {
      return kb.toString() + 'KB';
    }
    return (kb / 1024).toFixed(1) + 'MB';
  }

  build() {
    Row({ space: $r('app.float.space_s') }) {
      Column({ space: $r('app.float.space_xxs') }) {
        Text(this.timeText())
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text($r('app.string.backup_snapshot_size', this.sizeText()))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button($r('app.string.backup_snapshot_restore'))
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_brand'))
        .enabled(this.rowEnabled)
        .onClick(() => {
          this.onRestore(this.info);
        })
      Button($r('app.string.backup_snapshot_delete'))
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_danger'))
        .enabled(this.rowEnabled)
        .onClick(() => {
          this.onDelete(this.info);
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_m'),
      right: $r('app.float.space_m'),
      top: $r('app.float.space_s'),
      bottom: $r('app.float.space_s')
    })
  }
}

/**
 * 整宽主按钮：长任务进行中禁用并显示「处理中…」。
 * 做成 @ComponentV2 而不是多参 @Builder —— 多参 @Builder 的入参变化不会触发重建，
 * 「导出备份」就会一直停在旧文案上。
 */
@ComponentV2
struct BackupPrimaryButton {
  @Param label: ResourceStr = '';
  @Param buttonEnabled: boolean = true;
  @Event onTap: () => void = () => {
  };

  build() {
    Button(this.label)
      .buttonStyle(ButtonStyleMode.NORMAL)
      .width('100%')
      .height($r('app.float.row_height'))
      .fontSize($r('app.float.font_size_body'))
      .fontColor($r('app.color.hm_on_brand'))
      .backgroundColor(this.buttonEnabled ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary'))
      .enabled(this.buttonEnabled)
      .onClick(() => {
        this.onTap();
      })
  }
}

/** 最近一次导入 / 恢复的统计卡片。 */
@ComponentV2
struct BackupResultCard {
  @Param summary: BackupSummary = new BackupSummary();
  @Param finishedAt: number = 0;

  build() {
    Column() {
      Row() {
        Text($r('app.string.backup_result_title'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        Blank()
        Text(this.finishedAt > 0 ? DateUtil.format(this.finishedAt) : '')
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
      }
      .width('100%')
      .height($r('app.float.row_height'))
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })

      Divider().color($r('app.color.hm_divider'))
      BackupStatRow({ label: $r('app.string.backup_result_label_feeds'), value: this.summary.feedsAdded })
      Divider().color($r('app.color.hm_divider'))
      BackupStatRow({ label: $r('app.string.backup_result_label_articles'), value: this.summary.articlesAdded })
      if (this.summary.articlesUpdated > 0) {
        Divider().color($r('app.color.hm_divider'))
        BackupStatRow({ label: $r('app.string.backup_result_label_updated'), value: this.summary.articlesUpdated })
      }
      Divider().color($r('app.color.hm_divider'))
      BackupStatRow({ label: $r('app.string.backup_result_label_highlights'), value: this.summary.highlightsAdded })
      Divider().color($r('app.color.hm_divider'))
      BackupStatRow({ label: $r('app.string.backup_result_label_tags'), value: this.summary.tagsAdded })
      Divider().color($r('app.color.hm_divider'))
      BackupStatRow({ label: $r('app.string.backup_result_label_skipped'), value: this.summary.skipped })
      if (this.summary.failed > 0) {
        Divider().color($r('app.color.hm_divider'))
        BackupStatRow({
          label: $r('app.string.backup_result_label_failed'),
          value: this.summary.failed,
          danger: true
        })
      }
    }
    .width('100%')
    // 与上方导入卡留出间距（本组件只在这里使用，margin 固定即可）。
    .margin({ top: $r('app.float.space_xl') })
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }
}

@ComponentV2
export struct BackupView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  /** 页面已销毁：延迟补读的结果不再写状态。 */
  private disposed: boolean = false;

  /**
   * 进页面先读一次本地快照列表。
   * 冷启动时 Index.onPageShow 可能刚触发自动快照、还在写文件：列表为空就延迟补读一次，
   * 避免用户第一次进来看到「暂无快照」而实际上快照马上就写好了。
   */
  aboutToAppear(): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      return;
    }
    backupViewModel.refreshSnapshots(context).then(() => {
      if (backupViewModel.snapshots.length > 0) {
        return;
      }
      setTimeout(() => {
        if (this.disposed) {
          return;
        }
        const retryContext: common.Context | undefined = this.hostContext();
        if (retryContext !== undefined) {
          backupViewModel.refreshSnapshots(retryContext).then(() => {
          });
        }
      }, SNAPSHOT_RETRY_MS);
    });
    backupViewModel.refreshCloud(context);
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  private hostContext(): common.Context | undefined {
    return this.getUIContext().getHostContext();
  }

  /** 当前错误 key → 文案；没有错误时按导出失败兜底（快照/导入各有自己的 key）。 */
  private errorText(): ResourceStr {
    const key: string = backupViewModel.lastError;
    if (key === BackupError.BUSY) {
      return $r('app.string.backup_error_busy');
    }
    if (key === BackupError.IMPORT) {
      return $r('app.string.backup_error_parse');
    }
    if (key === BackupError.SNAPSHOT) {
      return $r('app.string.backup_error_snapshot');
    }
    return $r('app.string.backup_error_write');
  }

  /** 导出：成功后提示；用户取消不报错，只提示「已取消」；其余按失败提示。 */
  private runExport(): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      return;
    }
    backupViewModel.exportNow(context).then((ok: boolean) => {
      if (ok) {
        ToastUtil.show(this.getUIContext(), $r('app.string.backup_toast_exported'));
        return;
      }
      ToastUtil.show(this.getUIContext(), backupViewModel.lastCancelled
        ? $r('app.string.backup_export_cancelled')
        : this.errorText());
    });
  }

  /** 导入：成功后展示统计（并已刷新列表与计数）；取消只提示已取消。 */
  private runImport(): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      return;
    }
    backupViewModel.importNow(context).then((summary: BackupSummary | undefined) => {
      if (summary !== undefined) {
        ToastUtil.show(this.getUIContext(), $r('app.string.backup_toast_imported'));
        return;
      }
      ToastUtil.show(this.getUIContext(), backupViewModel.lastCancelled
        ? $r('app.string.backup_import_cancelled')
        : this.errorText());
    });
  }

  /** 立即生成一份当日快照（同一天覆盖），成功后列表自动刷新。 */
  private runSnapshotNow(): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      return;
    }
    backupViewModel.snapshotNow(context).then((ok: boolean) => {
      ToastUtil.show(this.getUIContext(), ok
        ? $r('app.string.backup_toast_snapshot_created')
        : this.errorText());
    });
  }

  /** 备份到云空间：成功提示已写入（系统随后自动上云）。 */
  private runCloudBackup(): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      return;
    }
    backupViewModel.backupToCloud(context).then((ok: boolean) => {
      ToastUtil.show(this.getUIContext(), ok
        ? $r('app.string.backup_toast_cloud_saved')
        : this.errorText());
    });
  }

  /** 从云空间恢复前二次确认：同样是合并语义，不会删除本地数据。 */
  private confirmCloudRestore(): void {
    if (backupViewModel.busy() || !backupViewModel.cloudExists) {
      return;
    }
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const confirmButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.backup_cloud_restore_action'),
      fontColor: $r('app.color.hm_brand'),
      action: () => {
        this.runCloudRestore();
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.backup_confirm_restore_title'),
      message: $r('app.string.backup_confirm_restore_message'),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: confirmButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  private runCloudRestore(): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      return;
    }
    backupViewModel.restoreFromCloud(context).then((summary: BackupSummary | undefined) => {
      ToastUtil.show(this.getUIContext(), summary !== undefined
        ? $r('app.string.backup_toast_restored')
        : this.errorText());
    });
  }

  /** 恢复快照前二次确认：合并语义，不会删除现有数据。 */
  private confirmRestore(info: SnapshotInfo): void {
    if (backupViewModel.busy()) {
      return;
    }
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const confirmButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.backup_snapshot_restore'),
      fontColor: $r('app.color.hm_brand'),
      action: () => {
        this.restoreSnapshot(info);
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.backup_confirm_restore_title'),
      message: $r('app.string.backup_confirm_restore_message'),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: confirmButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  private restoreSnapshot(info: SnapshotInfo): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      return;
    }
    backupViewModel.restore(context, info).then((ok: boolean) => {
      ToastUtil.show(this.getUIContext(), ok
        ? $r('app.string.backup_toast_restored')
        : this.errorText());
    });
  }

  /** 删除快照前二次确认：文件删除不可恢复。 */
  private confirmDelete(info: SnapshotInfo): void {
    if (backupViewModel.busy()) {
      return;
    }
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const confirmButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.backup_snapshot_delete'),
      fontColor: $r('app.color.hm_danger'),
      action: () => {
        this.deleteSnapshot(info);
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.backup_confirm_delete_title'),
      message: $r('app.string.backup_confirm_delete_message'),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: confirmButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  private deleteSnapshot(info: SnapshotInfo): void {
    const context: common.Context | undefined = this.hostContext();
    if (context === undefined) {
      return;
    }
    backupViewModel.remove(context, info).then((ok: boolean) => {
      ToastUtil.show(this.getUIContext(), ok
        ? $r('app.string.backup_toast_deleted')
        : this.errorText());
    });
  }

  @Builder
  SectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize($r('app.float.font_size_section'))
      .fontColor($r('app.color.hm_text_secondary'))
      .margin({ top: $r('app.float.space_xl'), bottom: $r('app.float.space_s'), left: $r('app.float.space_xs') })
  }

  /** 导出卡片：内容清单 + 导出按钮 + 隐私提示 + 失败原因。 */
  @Builder
  ExportCard() {
    Column({ space: $r('app.float.space_s') }) {
      Text($r('app.string.backup_export_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
      Text($r('app.string.backup_content_list'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      BackupPrimaryButton({
        label: backupViewModel.exporting
          ? $r('app.string.backup_working')
          : $r('app.string.backup_export_action'),
        buttonEnabled: !backupViewModel.busy(),
        onTap: () => {
          this.runExport();
        }
      })

      // 失败就地留在页面上（Toast 会消失，用户回头看还能知道原因）。
      if (backupViewModel.lastError.length > 0) {
        Text(this.errorText())
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .width('100%')
      }

      Text($r('app.string.backup_privacy_notice'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 导入卡片：「同时恢复设置」开关 + 导入按钮。 */
  @Builder
  ImportCard() {
    Column({ space: $r('app.float.space_s') }) {
      Text($r('app.string.backup_import_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      Row() {
        Text($r('app.string.backup_restore_settings'))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: backupViewModel.restoreSettings })
          .selectedColor($r('app.color.hm_brand'))
          .enabled(!backupViewModel.busy())
          .onChange((value: boolean) => {
            backupViewModel.setRestoreSettings(value);
          })
      }
      .width('100%')
      .height($r('app.float.row_height'))

      Text($r('app.string.backup_restore_settings_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      BackupPrimaryButton({
        label: backupViewModel.importing
          ? $r('app.string.backup_working')
          : $r('app.string.backup_import_action'),
        buttonEnabled: !backupViewModel.busy(),
        onTap: () => {
          this.runImport();
        }
      })
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 云空间备份卡片：说明 + 上次备份时间 + 备份 / 恢复按钮。 */
  @Builder
  CloudCard() {
    Column({ space: $r('app.float.space_s') }) {
      Text($r('app.string.backup_cloud_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      // 云目录不可用（系统 / 云空间版本过低）：只说明原因，不提供按钮。
      if (!backupViewModel.cloudAvailable) {
        Text($r('app.string.backup_cloud_unavailable'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .width('100%')
      } else {
        Text(backupViewModel.cloudExists
          ? $r('app.string.backup_cloud_last', DateUtil.format(backupViewModel.cloudAt))
          : $r('app.string.backup_cloud_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')

        BackupPrimaryButton({
          label: backupViewModel.exporting
            ? $r('app.string.backup_working')
            : $r('app.string.backup_cloud_save_action'),
          buttonEnabled: !backupViewModel.busy(),
          onTap: () => {
            this.runCloudBackup();
          }
        })

        BackupPrimaryButton({
          label: backupViewModel.importing
            ? $r('app.string.backup_working')
            : $r('app.string.backup_cloud_restore_action'),
          buttonEnabled: !backupViewModel.busy() && backupViewModel.cloudExists,
          onTap: () => {
            this.confirmCloudRestore();
          }
        })
      }

      Text($r('app.string.backup_cloud_privacy'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 快照卡片：保留说明 + 立即备份 + 列表（时间 / 大小 / 恢复 / 删除）。 */
  @Builder
  SnapshotCard() {
    Column() {
      Row({ space: $r('app.float.space_s') }) {
        Column({ space: $r('app.float.space_xxs') }) {
          Text($r('app.string.backup_snapshot_keep_hint'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
          // 没有快照时不显示「上次快照」行：下面的「暂无快照」已经说明了状态。
          if (backupViewModel.snapshots.length > 0) {
            Text($r('app.string.backup_last_snapshot',
              DateUtil.format(backupViewModel.snapshots[0].createdAt)))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(backupViewModel.exporting
          ? $r('app.string.backup_working')
          : $r('app.string.backup_snapshot_now'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .enabled(!backupViewModel.busy())
          .onClick(() => {
            this.runSnapshotNow();
          })
      }
      .width('100%')
      .padding($r('app.float.space_m'))

      Divider().color($r('app.color.hm_divider'))

      if (backupViewModel.snapshots.length === 0) {
        Text($r('app.string.backup_snapshot_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding($r('app.float.space_xl'))
      } else {
        ForEach(backupViewModel.snapshots, (item: SnapshotInfo, index: number) => {
          Column() {
            BackupSnapshotRow({
              info: item,
              rowEnabled: !backupViewModel.busy(),
              onRestore: (info: SnapshotInfo) => {
                this.confirmRestore(info);
              },
              onDelete: (info: SnapshotInfo) => {
                this.confirmDelete(info);
              }
            })
            if (index < backupViewModel.snapshots.length - 1) {
              Divider().color($r('app.color.hm_divider'))
            }
          }
          .width('100%')
        }, (item: SnapshotInfo) => item.fileName)
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // 透明标题栏占位：内容从标题栏下方滚过，首屏不被遮挡。
        Row().width('100%').height(safeArea.contentTopInsetVp)

        Text($r('app.string.backup_intro'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs'), right: $r('app.float.space_xs') })

        this.SectionTitle($r('app.string.backup_section_export'))
        this.ExportCard()

        this.SectionTitle($r('app.string.backup_section_import'))
        this.ImportCard()

        // 云空间：走端云文件协同，数据存在用户自己的云空间，不需要开发者服务端。
        this.SectionTitle($r('app.string.backup_section_cloud'))
        this.CloudCard()

        if (backupViewModel.summary !== undefined) {
          // 统计卡自带上标题行，不再额外画分区标题（避免「最近一次结果」重复两次）。
          BackupResultCard({
            summary: backupViewModel.summary,
            finishedAt: backupViewModel.lastActionAt
          })
        }

        this.SectionTitle($r('app.string.backup_section_snapshots'))
        this.SnapshotCard()

        // 底部预留：避让悬浮页签栏与系统导航条。
        Blank().height(safeArea.contentBottomInsetVp)
      }
      .width('100%')
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    // Scroll 默认会把「内容比视口短」的内容整体居中，首屏顶部会多出一条空白；固定从顶部排。
    .align(Alignment.TopStart)
    .clip(false)
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
