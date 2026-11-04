import { BackupSummary, SnapshotInfo } from '../model/Backup';
import { DateUtil } from '../common/utils/DateUtil';
import { themePalette } from '../model/ThemePalette';

/**
 * 统计行：标签 + 数值。
 * 单独做成 @ComponentV2：多参 @Builder 传入两个及以上参数时不随状态刷新，
 * 而导入统计会在同一次会话里被第二次导入改写。
 */
@ComponentV2
export struct BackupStatRow {
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
export struct BackupSnapshotRow {
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
        .fontColor(themePalette.accent())
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
export struct BackupPrimaryButton {
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
      .backgroundColor(this.buttonEnabled ? themePalette.fill() : $r('app.color.hm_text_secondary'))
      .enabled(this.buttonEnabled)
      .onClick(() => {
        this.onTap();
      })
  }
}

/** 最近一次导入 / 恢复的统计卡片。 */
@ComponentV2
export struct BackupResultCard {
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
