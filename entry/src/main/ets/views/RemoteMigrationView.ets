/*
 * RemoteMigrationView.ets — 订阅迁移 / 服务模式选择页（NavDestination 内容，纯状态管理 V2）。
 *
 * 三种模式：
 *   - merge：远端源并入本地，本地独有源保留（默认）；
 *   - migrated：把本地独有源逐个订阅到远端；
 *   - remoteOnly：远端为权威，本地独有源停用但保留历史，可随时切回合并恢复。
 *
 * 业务逻辑在 RemoteSyncService，本页只读 ViewModel 并上报选择。
 */

import { safeArea } from '../service/SafeAreaController';
import { remoteAccountViewModel } from '../viewmodel/RemoteAccountViewModel';
import {
  RemoteErrorCode,
  RemoteMigrationMode,
  RemoteMigrationPreview,
  RemoteMigrationResult
} from '../model/Remote';
import { ToastUtil } from '../common/utils/ToastUtil';

@ComponentV2
export struct RemoteMigrationView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  @Local selectedMode: string = '';

  /** 非空预览（build 里做类型收窄；未加载时返回空计数）。 */
  private preview(): RemoteMigrationPreview {
    const value: RemoteMigrationPreview | undefined = remoteAccountViewModel.migrationPreview;
    return value !== undefined ? value : new RemoteMigrationPreview(0, 0, 0, 0, '');
  }

  aboutToAppear(): void {
    this.loadPreview();
  }

  private loadPreview(): void {
    remoteAccountViewModel.loadMigrationPreview().then(() => {
      const preview: RemoteMigrationPreview | undefined = remoteAccountViewModel.migrationPreview;
      if (preview !== undefined && this.selectedMode.length === 0) {
        this.selectedMode = preview.mode.length > 0 ? preview.mode : RemoteMigrationMode.MERGE;
      }
    });
  }

  private apply(): void {
    if (this.selectedMode.length === 0 || remoteAccountViewModel.migrationApplying) {
      return;
    }
    remoteAccountViewModel.applyMigration(this.selectedMode).then((result: RemoteMigrationResult | undefined) => {
      if (result === undefined) {
        return;
      }
      if (result.failed > 0) {
        ToastUtil.show(this.getUIContext(), $r('app.string.remote_migration_partial', result.failed));
        return;
      }
      if (result.mode === RemoteMigrationMode.MIGRATED) {
        ToastUtil.show(this.getUIContext(), $r('app.string.remote_migration_done_migrated', result.pushed));
      } else if (result.mode === RemoteMigrationMode.REMOTE_ONLY) {
        ToastUtil.show(this.getUIContext(), $r('app.string.remote_migration_done_remote_only', result.disabled));
      } else {
        ToastUtil.show(this.getUIContext(), $r('app.string.remote_migration_done_merge'));
      }
      this.navPathStack.pop();
    });
  }

  @Builder
  SectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize($r('app.float.font_size_section'))
      .fontColor($r('app.color.hm_text_secondary'))
      .margin({
        top: $r('app.float.space_xl'),
        bottom: $r('app.float.space_s'),
        left: $r('app.float.space_xs')
      })
  }

  @Builder
  InfoRow(label: ResourceStr, value: string) {
    Row() {
      Text(label)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_primary'))
      Blank()
      Text(value)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
    }
    .width('100%')
    .constraintSize({ minHeight: $r('app.float.row_height') })
    .padding({
      left: $r('app.float.space_m'),
      right: $r('app.float.space_m'),
      top: $r('app.float.space_s'),
      bottom: $r('app.float.space_s')
    })
  }

  @Builder
  ModeRow(mode: string, title: ResourceStr, desc: ResourceStr) {
    Row({ space: $r('app.float.space_m') }) {
      SymbolGlyph(this.selectedMode === mode ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.circle'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.selectedMode === mode ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
      Column({ space: $r('app.float.space_xxs') }) {
        Text(title)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .width('100%')
        Text(desc)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .onClick(() => {
      this.selectedMode = mode;
    })
  }

  @Builder
  PreviewCard(preview: RemoteMigrationPreview) {
    Column() {
      this.InfoRow($r('app.string.remote_migration_local_total'), preview.localTotal.toString())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.remote_migration_remote_total'), preview.remoteTotal.toString())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.remote_migration_overlap'), preview.overlap.toString())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.remote_migration_local_only'), preview.localOnly.toString())
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  @Builder
  OptionsCard() {
    Column() {
      this.ModeRow(RemoteMigrationMode.MERGE,
        $r('app.string.remote_migration_mode_merge'),
        $r('app.string.remote_migration_mode_merge_desc'))
      Divider().color($r('app.color.hm_divider'))
      this.ModeRow(RemoteMigrationMode.MIGRATED,
        $r('app.string.remote_migration_mode_migrated'),
        $r('app.string.remote_migration_mode_migrated_desc'))
      Divider().color($r('app.color.hm_divider'))
      this.ModeRow(RemoteMigrationMode.REMOTE_ONLY,
        $r('app.string.remote_migration_mode_remote_only'),
        $r('app.string.remote_migration_mode_remote_only_desc'))
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        Row().width('100%').height(safeArea.contentTopInsetVp)

        Text($r('app.string.remote_migration_desc'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .padding({ top: $r('app.float.space_s') })

        if (remoteAccountViewModel.migrationLoading) {
          Row({ space: $r('app.float.space_s') }) {
            LoadingProgress()
              .width($r('app.float.icon_size'))
              .height($r('app.float.icon_size'))
              .color($r('app.color.hm_brand'))
            Text($r('app.string.remote_migration_loading'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
          }
          .width('100%')
          .padding($r('app.float.space_l'))
        } else if (remoteAccountViewModel.migrationPreview !== undefined) {
          this.SectionTitle($r('app.string.remote_migration_section_preview'))
          this.PreviewCard(this.preview())

          this.SectionTitle($r('app.string.remote_migration_section_mode'))
          this.OptionsCard()

          Text($r('app.string.remote_migration_note'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })

          Button(remoteAccountViewModel.migrationApplying
            ? $r('app.string.remote_migration_applying')
            : $r('app.string.remote_migration_apply'))
            .buttonStyle(ButtonStyleMode.NORMAL)
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_on_brand'))
            .backgroundColor($r('app.color.hm_brand'))
            .width('100%')
            .height($r('app.float.row_height'))
            .margin({ top: $r('app.float.space_xl') })
            .enabled(!remoteAccountViewModel.migrationApplying)
            .onClick(() => {
              this.apply();
            })
        }

        if (remoteAccountViewModel.errorCode !== RemoteErrorCode.NONE) {
          Text(remoteAccountViewModel.errorText(remoteAccountViewModel.errorCode))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_danger'))
            .width('100%')
            .margin({ top: $r('app.float.space_m') })
          Button($r('app.string.remote_migration_retry'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_brand'))
            .onClick(() => {
              this.loadPreview();
            })
        }

        Blank().height(safeArea.contentBottomInsetVp)
      }
      .width('100%')
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .clip(false)
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
