/*
 * FeedSettingsView.ets — 单源设置页（纯展示 + 事件上报）。
 *
 * 可覆盖项：启用抓取、抓取间隔、全文策略、保留天数、通知、滚动即已读；
 * 底部展示源健康状态（最后成功时间 / 连续失败次数 / 最近错误）并支持手动重试。
 * 设置归一与落盘在 FeedViewModel.updateFeedSettings。
 */

import { FeedSettingsPatch, FeedSource } from '../model/Feed';
import {
  ChoiceOption,
  ChoiceSet,
  FEED_INTERVAL_OPTIONS,
  FEED_RETENTION_OPTIONS,
  FULLTEXT_MODE_OPTIONS,
  TRI_STATE_OPTIONS
} from '../model/SettingsOptions';
import { FeedIntervalMinutes, RetentionDaysValue } from '../common/constants/SettingsConstants';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { appSettings } from '../model/AppSettings';
import { safeArea } from '../service/SafeAreaController';
import { MaterialController } from '../service/MaterialController';
import { DateUtil } from '../common/utils/DateUtil';
import { ToastUtil } from '../common/utils/ToastUtil';

/** 下拉选项行（自己按当前 id 取文案并弹 Menu）。 */
@ComponentV2
struct FeedOptionRow {
  @Param icon: Resource = $r('sys.symbol.gearshape');
  @Param title: ResourceStr = '';
  @Param currentId: string = '';
  @Param choice: ChoiceSet = TRI_STATE_OPTIONS;
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
    .borderRadius($r('app.float.radius_menu_item'))
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
      Row({ space: $r('app.float.space_m') }) {
        SymbolGlyph(this.icon)
          .fontSize($r('app.float.icon_size'))
          .fontColor([$r('app.color.hm_brand')])
        Text(this.title)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
      }
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
export struct FeedSettingsView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  /** 重试在途。 */
  @Local retrying: boolean = false;

  /** 当前编辑的订阅源；源已被删除时返回 undefined（页面显示空态）。 */
  private feed(): FeedSource | undefined {
    return feedViewModel.feedById(feedViewModel.settingsFeedId);
  }

  private patch(feed: FeedSource, patch: FeedSettingsPatch): void {
    feedViewModel.updateFeedSettings(feed.id, patch);
  }

  /** 源级保留天数 → 选项 id（0 = 跟随全局；-1 = 永久）。 */
  private retentionId(feed: FeedSource): string {
    if (feed.retentionDays === 0) {
      return 'global';
    }
    return RetentionDaysValue.idOf(feed.retentionDays);
  }

  /** 选项 id → 源级保留天数（'global' → 0；'forever' → -1）。 */
  private retentionValue(id: string): number {
    if (id === 'global') {
      return 0;
    }
    if (id === 'forever') {
      return RetentionDaysValue.FOREVER;
    }
    return Number(id);
  }

  private retry(feed: FeedSource): void {
    if (this.retrying || !feed.enabled) {
      return;
    }
    this.retrying = true;
    feedViewModel.retryFeed(feed.id).then(() => {
      this.retrying = false;
      ToastUtil.show(this.getUIContext(), feed.lastError.length > 0
        ? $r('app.string.toast_action_failed')
        : $r('app.string.snack_refreshed'));
    }).catch(() => {
      this.retrying = false;
      ToastUtil.show(this.getUIContext(), $r('app.string.toast_action_failed'));
    });
  }

  @Builder
  SectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize($r('app.float.font_size_section'))
      .fontColor($r('app.color.hm_text_secondary'))
      .margin({ top: $r('app.float.space_xl'), bottom: $r('app.float.space_s'), left: $r('app.float.space_xs') })
  }

  /** 启用抓取开关（停用后不抓取不通知，历史保留）。 */
  @Builder
  EnabledCard(feed: FeedSource) {
    Column() {
      Row() {
        Row({ space: $r('app.float.space_m') }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize($r('app.float.icon_size'))
            .fontColor([$r('app.color.hm_brand')])
          Text($r('app.string.feed_settings_enabled'))
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_text_primary'))
        }
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: feed.enabled })
          .selectedColor($r('app.color.hm_brand'))
          .onChange((value: boolean) => {
            const patch: FeedSettingsPatch = new FeedSettingsPatch();
            patch.enabled = value;
            this.patch(feed, patch);
          })
      }
      .width('100%')
      .height($r('app.float.row_height'))
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })

      Text($r('app.string.feed_settings_enabled_hint'))
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

  /** 抓取 / 全文 / 保留 / 通知 / 滚动已读。 */
  @Builder
  PolicyCard(feed: FeedSource) {
    Column() {
      FeedOptionRow({
        icon: $r('sys.symbol.arrow_clockwise'),
        title: $r('app.string.feed_settings_interval'),
        currentId: FeedIntervalMinutes.idOf(feed.fetchIntervalMinutes),
        choice: FEED_INTERVAL_OPTIONS,
        onPick: (id: string) => {
          const patch: FeedSettingsPatch = new FeedSettingsPatch();
          patch.fetchIntervalMinutes = FeedIntervalMinutes.of(id);
          this.patch(feed, patch);
        }
      })
      Divider().color($r('app.color.hm_divider'))
      FeedOptionRow({
        icon: $r('sys.symbol.doc_text'),
        title: $r('app.string.feed_settings_fulltext'),
        currentId: feed.fullTextMode,
        choice: FULLTEXT_MODE_OPTIONS,
        onPick: (id: string) => {
          const patch: FeedSettingsPatch = new FeedSettingsPatch();
          patch.fullTextMode = id;
          this.patch(feed, patch);
        }
      })
      Divider().color($r('app.color.hm_divider'))
      FeedOptionRow({
        icon: $r('sys.symbol.externaldrive'),
        title: $r('app.string.feed_settings_retention'),
        currentId: this.retentionId(feed),
        choice: FEED_RETENTION_OPTIONS,
        onPick: (id: string) => {
          const patch: FeedSettingsPatch = new FeedSettingsPatch();
          patch.retentionDays = this.retentionValue(id);
          this.patch(feed, patch);
        }
      })
      Divider().color($r('app.color.hm_divider'))
      FeedOptionRow({
        icon: $r('sys.symbol.bell'),
        title: $r('app.string.feed_settings_notify'),
        currentId: feed.notify,
        choice: TRI_STATE_OPTIONS,
        onPick: (id: string) => {
          const patch: FeedSettingsPatch = new FeedSettingsPatch();
          patch.notify = id;
          this.patch(feed, patch);
        }
      })
      Divider().color($r('app.color.hm_divider'))
      FeedOptionRow({
        icon: $r('sys.symbol.text_alignleft'),
        title: $r('app.string.feed_settings_scroll_read'),
        currentId: feed.markReadOnScroll,
        choice: TRI_STATE_OPTIONS,
        onPick: (id: string) => {
          const patch: FeedSettingsPatch = new FeedSettingsPatch();
          patch.markReadOnScroll = id;
          this.patch(feed, patch);
        }
      })
      Text($r('app.string.feed_settings_scroll_read_hint'))
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

  /** 源健康：最后成功时间 / 连续失败次数 / 最近错误 / 手动重试。 */
  @Builder
  HealthCard(feed: FeedSource) {
    Column({ space: $r('app.float.space_s') }) {
      Row({ space: $r('app.float.space_m') }) {
        Text(feed.lastUpdated > 0
          ? $r('app.string.health_last_success', DateUtil.format(feed.lastUpdated))
          : $r('app.string.health_never'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        Blank()
        Text(feed.failureCount > 0
          ? $r('app.string.health_failure_count', feed.failureCount)
          : $r('app.string.health_ok'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(feed.failureCount > 0 ? $r('app.color.hm_danger') : $r('app.color.hm_text_secondary'))
      }
      .width('100%')

      if (feed.lastError.length > 0) {
        Text(feed.lastError)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Row() {
        Blank()
        Button(this.retrying ? $r('app.string.health_retrying') : $r('app.string.health_retry'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor(feed.enabled ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary'))
          .enabled(feed.enabled && !this.retrying)
          .onClick(() => {
            this.retry(feed);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        Row().width('100%').height(safeArea.contentTopInsetVp)

        if (this.feed() === undefined) {
          Text($r('app.string.subs_empty'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding($r('app.float.space_2xl'))
        } else {
          this.SectionTitle($r('app.string.feed_settings_section_policy'))
          this.EnabledCard(this.feed() as FeedSource)
          this.SectionTitle($r('app.string.feed_settings_interval'))
          this.PolicyCard(this.feed() as FeedSource)
          this.SectionTitle($r('app.string.feed_settings_section_health'))
          this.HealthCard(this.feed() as FeedSource)
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
