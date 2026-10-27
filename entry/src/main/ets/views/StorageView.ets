/*
 * StorageView.ets — 「存储与保留」页（纯展示 + 事件上报）。
 *
 * 内容：全局保留策略（模式 / 天数）、总占用与按源占用、可清理条数、立即清理（二次确认）、
 * 回收站恢复、检索索引重建（带进度）。业务逻辑在 StorageViewModel。
 */

import { appSettings } from '../model/AppSettings';
import { ChoiceOption, ChoiceSet, RETENTION_DAYS_OPTIONS, RETENTION_MODE_OPTIONS } from '../model/SettingsOptions';
import { RetentionMode } from '../common/constants/SettingsConstants';
import { SearchConstants } from '../common/constants/RssConstants';
import { FeedStorageStat } from '../model/Search';
import { storageViewModel } from '../viewmodel/StorageViewModel';
import { safeArea } from '../service/SafeAreaController';
import { MaterialController } from '../service/MaterialController';
import { ToastUtil } from '../common/utils/ToastUtil';

/** 下拉选项行：自己按当前 id 取文案并弹 Menu。 */
@ComponentV2
struct StorageOptionRow {
  @Param title: ResourceStr = '';
  @Param currentId: string = '';
  @Param choice: ChoiceSet = RETENTION_MODE_OPTIONS;
  @Event onPick: (id: string) => void = () => {};

  @Builder
  ItemContent(option: ChoiceOption) {
    Row() {
      Text(option.label)
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(option.id === this.currentId ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(option.id === this.currentId ? $r('app.color.hm_brand') : $r('app.color.hm_text_primary'))
    }
    .width('100%')
    .height($r('app.float.menu_item_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    .alignItems(VerticalAlign.Center)
    .margin({ left: $r('app.float.space_xs'), right: $r('app.float.space_xs') })
    .backgroundColor(option.id === this.currentId
      ? $r('app.color.hm_menu_item_selected')
      : $r('app.color.hm_page_transparent'))
    // 与菜单容器圆角一致，避免内外圆角不一致。
    .borderRadius($r('app.float.radius_card'))
    .onClick(() => {
      this.onPick(option.id);
    })
  }

  @Builder
  OptionMenu() {
    Menu() {
      ForEach(this.choice.options, (option: ChoiceOption) => {
        MenuItem(this.ItemContent(option))
      }, (option: ChoiceOption) => option.id)
    }
    .width($r('app.float.menu_width'))
    .radius($r('app.float.radius_card'))
  }

  build() {
    Row() {
      Text(this.title)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
      Blank()
      Row({ space: $r('app.float.space_xs') }) {
        Text(this.choice.labelOf(this.currentId))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
        SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
          .fontSize($r('app.float.icon_size_tiny'))
          .fontColor([$r('app.color.hm_text_primary')])
      }
      .height($r('app.float.value_chip_height'))
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
      .backgroundColor($r('app.color.hm_value_chip_background'))
      .borderRadius($r('app.float.radius_chip'))
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    .bindMenu(this.OptionMenu(),
      MaterialController.menuOptions({ placement: Placement.BottomRight }, appSettings.immersiveOn))
  }
}

@ComponentV2
export struct StorageView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  /** 按源占用默认只显示前 N 条，可展开。 */
  @Local showAllFeeds: boolean = false;

  aboutToAppear(): void {
    storageViewModel.load();
  }

  /** 字符量 → 便于阅读的体积文案。 */
  private sizeText(chars: number): string {
    if (chars <= 0) {
      return '0KB';
    }
    const kb: number = Math.ceil(chars / 1024);
    if (kb < 1024) {
      return kb.toString() + 'KB';
    }
    return (kb / 1024).toFixed(1) + 'MB';
  }

  /** 按源占用展示列表（默认前 8 条）。 */
  private visibleFeeds(): FeedStorageStat[] {
    const all: FeedStorageStat[] = storageViewModel.stats.perFeed;
    return this.showAllFeeds || all.length <= 8 ? all : all.slice(0, 8);
  }

  /** 索引就绪状态文案：就绪 / 降级（不可用且本应有索引）。 */
  private readyText(ready: boolean): ResourceStr {
    return ready ? $r('app.string.search_diag_state_ready') : $r('app.string.search_diag_state_degraded');
  }

  /** 分词能力文案：可用 / 不可用。 */
  private capableText(capable: boolean): ResourceStr {
    return capable
      ? $r('app.string.search_diag_state_available')
      : $r('app.string.search_diag_state_unavailable');
  }

  /** 最近检索路径文案。 */
  private pathText(path: string): ResourceStr {
    if (path === SearchConstants.PATH_CJK) {
      return $r('app.string.search_diag_path_cjk');
    }
    if (path === SearchConstants.PATH_FTS) {
      return $r('app.string.search_diag_path_fts');
    }
    if (path === SearchConstants.PATH_LIKE) {
      return $r('app.string.search_diag_path_like');
    }
    return $r('app.string.search_diag_path_none');
  }

  /** 立即清理：先给出影响条数并要求确认。 */
  private confirmClean(): void {
    if (storageViewModel.cleanable <= 0 || storageViewModel.cleaning) {
      return;
    }
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const confirmButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.storage_clean_now'),
      fontColor: $r('app.color.hm_brand'),
      action: () => {
        storageViewModel.cleanNow().then((cleaned: number) => {
          ToastUtil.show(this.getUIContext(), $r('app.string.storage_clean_done', cleaned));
        });
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.storage_clean_confirm_title'),
      message: $r('app.string.storage_clean_confirm_message', storageViewModel.cleanable),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: confirmButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  private confirmRestore(): void {
    if (storageViewModel.stats.trashCount <= 0 || storageViewModel.restoring) {
      return;
    }
    storageViewModel.restoreAll().then((restored: number) => {
      ToastUtil.show(this.getUIContext(), $r('app.string.storage_restore_done', restored));
    });
  }

  @Builder
  SectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize($r('app.float.font_size_section'))
      .fontColor($r('app.color.hm_text_secondary'))
      .margin({ top: $r('app.float.space_xl'), bottom: $r('app.float.space_s'), left: $r('app.float.space_xs') })
  }

  /** 保留策略卡片：模式 + （days 模式时的）天数 + 保护说明。 */
  @Builder
  RetentionCard() {
    Column() {
      StorageOptionRow({
        title: $r('app.string.storage_retention_mode'),
        currentId: appSettings.retentionMode,
        choice: RETENTION_MODE_OPTIONS,
        onPick: (id: string) => {
          storageViewModel.setMode(id);
        }
      })
      if (appSettings.retentionMode === RetentionMode.DAYS) {
        Divider().color($r('app.color.hm_divider'))
        StorageOptionRow({
          title: $r('app.string.retention_days_label'),
          currentId: appSettings.retentionDays,
          choice: RETENTION_DAYS_OPTIONS,
          onPick: (id: string) => {
            storageViewModel.setDays(id);
          }
        })
      }
      Text($r('app.string.storage_retention_hint'))
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
  }

  /** 占用卡片：总条数 / 文本占用 / 可清理条数 / 立即清理。 */
  @Builder
  UsageCard() {
    Column({ space: $r('app.float.space_s') }) {
      Row() {
        Text(storageViewModel.stats.articleCount > 0
          ? $r('app.string.storage_total', storageViewModel.stats.articleCount)
          : $r('app.string.storage_empty'))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
        Blank()
        Text($r('app.string.storage_text_size', this.sizeText(storageViewModel.stats.textBytes)))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
      }
      .width('100%')

      Row() {
        Text($r('app.string.storage_cleanable', storageViewModel.cleanable))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        Blank()
        Button($r('app.string.storage_clean_now'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor(storageViewModel.cleanable > 0
            ? $r('app.color.hm_brand')
            : $r('app.color.hm_text_secondary'))
          .enabled(storageViewModel.cleanable > 0 && !storageViewModel.cleaning)
          .onClick(() => {
            this.confirmClean();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  /** 按源占用。 */
  @Builder
  PerFeedCard() {
    Column() {
      ForEach(this.visibleFeeds(), (stat: FeedStorageStat) => {
        Row({ space: $r('app.float.space_s') }) {
          Text(stat.title.length > 0 ? stat.title : stat.feedId)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text($r('app.string.subs_article_count', stat.count))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
          Text(this.sizeText(stat.bytes))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
        .width('100%')
        .height($r('app.float.row_height'))
        .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
      }, (stat: FeedStorageStat) => stat.feedId)

      if (storageViewModel.stats.perFeed.length > 8) {
        Row() {
          Text(this.showAllFeeds ? $r('app.string.storage_show_less')
            : $r('app.string.storage_show_all'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_brand'))
        }
        .width('100%')
        .height($r('app.float.row_height'))
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.showAllFeeds = !this.showAllFeeds;
        })
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  /** 回收站卡片。 */
  @Builder
  TrashCard() {
    Row() {
      Text($r('app.string.storage_trash_count', storageViewModel.stats.trashCount))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
      Blank()
      Button($r('app.string.storage_restore'))
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_brand'))
        .enabled(storageViewModel.stats.trashCount > 0 && !storageViewModel.restoring)
        .onClick(() => {
          this.confirmRestore();
        })
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  /** 索引重建卡片。 */
  @Builder
  IndexCard() {
    Column({ space: $r('app.float.space_s') }) {
      Row() {
        Text(storageViewModel.rebuilding
          ? $r('app.string.storage_rebuilding', storageViewModel.rebuildDone, storageViewModel.rebuildTotal)
          : $r('app.string.storage_section_index'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        Blank()
        Button($r('app.string.storage_rebuild'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .enabled(!storageViewModel.rebuilding)
          .onClick(() => {
            storageViewModel.rebuildIndex().then(() => {
              ToastUtil.show(this.getUIContext(), $r('app.string.storage_rebuild_done'));
            });
          })
      }
      .width('100%')

      if (storageViewModel.rebuilding) {
        Progress({ value: Math.round(storageViewModel.progressRatio() * 100), total: 100 })
          .width('100%')
          .color($r('app.color.hm_brand'))
      }
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  /** 诊断分组里的一行：标题 + 右侧取值（就绪用品牌色，降级用次要色）。 */
  @Builder
  DiagRow(label: ResourceStr, value: ResourceStr, ok: boolean) {
    Row() {
      Text(label)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_primary'))
      Blank()
      Text(value)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor(ok ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
  }

  /** 检索索引诊断卡片：主索引 / 中文索引 / 分词能力 / 条数 / 最近检索路径与耗时。 */
  @Builder
  DiagnosticsCard() {
    Column() {
      this.DiagRow($r('app.string.search_diag_main_index'),
        $r('app.string.search_diag_indexed', storageViewModel.diagnostics.mainIndexed),
        storageViewModel.diagnostics.mainIndexReady)
      Divider().color($r('app.color.hm_divider'))
      this.DiagRow($r('app.string.search_diag_cjk_index'),
        $r('app.string.search_diag_indexed', storageViewModel.diagnostics.cjkIndexed),
        storageViewModel.diagnostics.cjkIndexReady)
      Divider().color($r('app.color.hm_divider'))
      this.DiagRow($r('app.string.search_diag_tokenizer'),
        this.capableText(storageViewModel.diagnostics.cjkFtsCapable),
        storageViewModel.diagnostics.cjkFtsCapable)
      Divider().color($r('app.color.hm_divider'))
      Row() {
        Text($r('app.string.search_diag_last_search'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_primary'))
        Blank()
        Text(this.pathText(storageViewModel.diagnostics.lastPath))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        if (storageViewModel.diagnostics.lastPath.length > 0) {
          Text(' · ' + storageViewModel.diagnostics.lastMillis.toString() + ' ms')
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
      }
      .width('100%')
      .height($r('app.float.row_height'))
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        Row().width('100%').height(safeArea.contentTopInsetVp)

        this.SectionTitle($r('app.string.storage_section_retention'))
        this.RetentionCard()

        this.SectionTitle($r('app.string.storage_section_usage'))
        this.UsageCard()

        this.SectionTitle($r('app.string.storage_section_per_feed'))
        this.PerFeedCard()

        this.SectionTitle($r('app.string.storage_section_trash'))
        this.TrashCard()

        this.SectionTitle($r('app.string.storage_section_index'))
        this.IndexCard()

        this.SectionTitle($r('app.string.search_diag_section'))
        this.DiagnosticsCard()

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
