/*
 * DiagnosticsView.ets — 「诊断与性能」页（NavDestination 内容，纯状态管理 V2）。
 *
 * 展示（全部来自本机，不上传）：
 *   - 启动到首屏耗时、本次启动时间、系统给的上次退出原因 / 详情（崩溃归类）；
 *   - 最近一轮抓取的总耗时 / 成功失败数 / 五类失败归因 / 最慢的源；
 *   - 当前源健康（连续失败次数与最后错误，点击进入源设置）；
 *   - 运行时事实（列表虚拟化、数据库索引、本地文章与正文缓存条数）；
 *   - 本地诊断开关与清除入口。
 *
 * 注意：不注册全局异常观测器，不拦截或改变系统默认的崩溃行为；
 * 「上次退出原因」只读取 UIAbility 启动参数。
 */

import { common } from '@kit.AbilityKit';
import { FeedSource } from '../model/Feed';
import { FeedFetchSample, ExitReasonKind, exitReasonKind, averageDuration } from '../model/Diagnostics';
import { diagnostics } from '../service/DiagnosticsService';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { articleStore, CacheStats } from '../service/ArticleStore';
import { appSettings } from '../model/AppSettings';
import { settingsStore } from '../service/SettingsStore';
import { DateUtil } from '../common/utils/DateUtil';
import { ToastUtil } from '../common/utils/ToastUtil';
import { safeArea } from '../service/SafeAreaController';
import { RouterConstants } from '../common/constants/RouterConstants';
import { CommonConstants } from '../common/constants/CommonConstants';

@ComponentV2
export struct DiagnosticsView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  @Local articleCount: number = 0;
  @Local cachedArticles: number = 0;
  @Local cachedChars: number = 0;
  @Local retrying: boolean = false;

  aboutToAppear(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context !== undefined) {
      diagnostics.init(context);
    }
    this.loadStorageStats();
  }

  private async loadStorageStats(): Promise<void> {
    this.articleCount = await articleStore.countAll();
    const stats: CacheStats = await articleStore.cacheStats();
    this.cachedArticles = stats.articles;
    this.cachedChars = stats.bytes;
  }

  /** 毫秒 / 秒的自适应显示。 */
  private msText(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    if (ms < 1000) {
      return ms.toString() + ' ms';
    }
    return (ms / 1000).toFixed(2) + ' s';
  }

  private firstScreenValue(): ResourceStr {
    if (diagnostics.firstScreenMs > 0) {
      return this.msText(diagnostics.firstScreenMs);
    }
    return $r('app.string.diagnostics_no_data');
  }

  private lastExitLabel(): ResourceStr {
    const kind: string = exitReasonKind(diagnostics.lastExitReason);
    if (kind === ExitReasonKind.NORMAL) {
      return $r('app.string.diagnostics_exit_normal');
    }
    if (kind === ExitReasonKind.JS_ERROR) {
      return $r('app.string.diagnostics_exit_js');
    }
    if (kind === ExitReasonKind.CPP_CRASH) {
      return $r('app.string.diagnostics_exit_cpp');
    }
    if (kind === ExitReasonKind.FREEZE) {
      return $r('app.string.diagnostics_exit_freeze');
    }
    if (kind === ExitReasonKind.RESOURCE) {
      return $r('app.string.diagnostics_exit_resource');
    }
    if (kind === ExitReasonKind.UPGRADE) {
      return $r('app.string.diagnostics_exit_upgrade');
    }
    if (kind === ExitReasonKind.USER) {
      return $r('app.string.diagnostics_exit_user');
    }
    if (kind === ExitReasonKind.UNKNOWN) {
      return $r('app.string.diagnostics_exit_unknown');
    }
    return $r('app.string.diagnostics_exit_other');
  }

  private lastFetchValue(): ResourceStr {
    const text: string = DateUtil.format(diagnostics.lastFetchAt);
    return text.length > 0 ? text : $r('app.string.diagnostics_no_data');
  }

  private lastExitDetailValue(): ResourceStr {
    const message: string = diagnostics.lastExitMessage.trim();
    return message.length > 0 ? message : $r('app.string.diagnostics_no_data');
  }

  /** 最近一次列表滚动采样的帧率 / 最差单帧。 */
  private frameRateValue(): ResourceStr {
    if (diagnostics.lastFps <= 0) {
      return $r('app.string.diagnostics_no_data');
    }
    return $r('app.string.diagnostics_runtime_fps_value',
      Math.round(diagnostics.lastFps), Math.round(diagnostics.worstFrameMs));
  }

  /** 当前失败源：连续失败次数降序。 */
  private failingFeeds(): FeedSource[] {
    const list: FeedSource[] = [];
    for (let i = 0; i < feedViewModel.feeds.length; i += 1) {
      const feed: FeedSource = feedViewModel.feeds[i];
      if (feed.failureCount > 0 || feed.lastError.length > 0) {
        list.push(feed);
      }
    }
    list.sort((a: FeedSource, b: FeedSource) => b.failureCount - a.failureCount);
    return list;
  }

  private retryAll(): void {
    if (this.retrying) {
      return;
    }
    this.retrying = true;
    feedViewModel.refreshAll(true).then(() => {
      this.retrying = false;
      this.loadStorageStats();
      ToastUtil.show(this.getUIContext(),
        $r('app.string.diagnostics_retry_done',
          diagnostics.lastFetchTotal, diagnostics.lastFetchFailed));
    }).catch(() => {
      this.retrying = false;
    });
  }

  private clearRecords(): void {
    diagnostics.clear();
    ToastUtil.show(this.getUIContext(), $r('app.string.diagnostics_cleared'));
  }

  private openFeed(feed: FeedSource): void {
    feedViewModel.openFeedSettings(feed);
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_FEED_SETTINGS, ''));
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
  InfoRow(label: ResourceStr, value: ResourceStr) {
    Row() {
      Text(label)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_primary'))
      Blank()
      Text(value)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .maxLines(2)
        .textAlign(TextAlign.End)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: $r('app.float.space_m') })
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
  StartupCard() {
    Column() {
      this.InfoRow($r('app.string.diagnostics_first_screen'), this.firstScreenValue())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.diagnostics_started_at'),
        DateUtil.format(diagnostics.startupAt))
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.diagnostics_last_exit'), this.lastExitLabel())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.diagnostics_last_exit_detail'), this.lastExitDetailValue())
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  @Builder
  FetchCard() {
    Column() {
      if (diagnostics.lastFetchAt <= 0) {
        Text($r('app.string.diagnostics_no_data'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .padding($r('app.float.space_m'))
      } else {
        this.InfoRow($r('app.string.diagnostics_fetch_last'), this.lastFetchValue())
        Divider().color($r('app.color.hm_divider'))
        this.InfoRow($r('app.string.diagnostics_fetch_duration'),
          this.msText(diagnostics.lastFetchDurationMs))
        Divider().color($r('app.color.hm_divider'))
        this.InfoRow($r('app.string.diagnostics_fetch_sources'),
          diagnostics.lastFetchTotal.toString())
        Divider().color($r('app.color.hm_divider'))
        this.InfoRow($r('app.string.diagnostics_fetch_ok'), diagnostics.lastFetchOk.toString())
        Divider().color($r('app.color.hm_divider'))
        this.InfoRow($r('app.string.diagnostics_fetch_failed'), diagnostics.lastFetchFailed.toString())
        Divider().color($r('app.color.hm_divider'))
        this.InfoRow($r('app.string.diagnostics_fetch_avg'),
          this.msText(averageDuration(diagnostics.lastFetchDurationMs, diagnostics.lastFetchTotal)))
        Divider().color($r('app.color.hm_divider'))
        this.InfoRow($r('app.string.diagnostics_session_runs'), diagnostics.sessionFetchRuns.toString())
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  @Builder
  FailureCard() {
    Column() {
      this.InfoRow($r('app.string.diagnostics_fail_timeout'), diagnostics.failTimeout.toString())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.diagnostics_fail_network'), diagnostics.failNetwork.toString())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.diagnostics_fail_http'), diagnostics.failHttp.toString())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.diagnostics_fail_content'), diagnostics.failContent.toString())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.diagnostics_fail_other'), diagnostics.failOther.toString())
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  @Builder
  SlowFeedRow(sample: FeedFetchSample) {
    Row({ space: $r('app.float.space_s') }) {
      Text(sample.title.length > 0 ? sample.title : sample.feedId)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(this.msText(sample.durationMs))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
      if (!sample.ok) {
        Text($r('app.string.diagnostics_fetch_failed'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
      }
    }
    .width('100%')
    .constraintSize({ minHeight: $r('app.float.row_height') })
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
  }

  @Builder
  SlowCard() {
    Column() {
      if (diagnostics.slowFeeds.length === 0) {
        Text($r('app.string.diagnostics_no_data'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .padding($r('app.float.space_m'))
      } else {
        ForEach(diagnostics.slowFeeds, (sample: FeedFetchSample, index: number) => {
          if (index > 0) {
            Divider().color($r('app.color.hm_divider'))
          }
          this.SlowFeedRow(sample)
        }, (sample: FeedFetchSample) => sample.feedId + ':' + sample.durationMs.toString())
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  @Builder
  HealthCard() {
    Column() {
      if (this.failingFeeds().length === 0) {
        Text($r('app.string.diagnostics_health_ok'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .padding($r('app.float.space_m'))
      } else {
        ForEach(this.failingFeeds(), (feed: FeedSource, index: number) => {
          if (index > 0) {
            Divider().color($r('app.color.hm_divider'))
          }
          Column({ space: $r('app.float.space_xxs') }) {
            Row({ space: $r('app.float.space_s') }) {
              Text(feed.title)
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.hm_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text($r('app.string.diagnostics_health_failures', feed.failureCount))
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_danger'))
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize($r('app.float.icon_size_small'))
                .fontColor([$r('app.color.hm_text_secondary')])
            }
            .width('100%')
            if (feed.lastError.length > 0) {
              Text(feed.lastError)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_text_secondary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
          }
          .width('100%')
          .padding({
            left: $r('app.float.space_m'),
            right: $r('app.float.space_m'),
            top: $r('app.float.space_s'),
            bottom: $r('app.float.space_s')
          })
          .alignItems(HorizontalAlign.Start)
          .onClick(() => {
            this.openFeed(feed);
          })
        }, (feed: FeedSource) => feed.id)
      }

      Divider().color($r('app.color.hm_divider'))
      Button(this.retrying
        ? $r('app.string.diagnostics_retrying')
        : $r('app.string.diagnostics_retry'))
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_brand'))
        .enabled(!this.retrying)
        .width('100%')
        .height($r('app.float.row_height'))
        .onClick(() => {
          this.retryAll();
        })
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  @Builder
  RuntimeCard() {
    Column() {
      this.InfoRow($r('app.string.diagnostics_runtime_articles'), this.articleCount.toString())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.diagnostics_runtime_cached'),
        $r('app.string.diagnostics_runtime_cached_value', this.cachedArticles, this.cachedChars))
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.diagnostics_runtime_virtualization'),
        $r('app.string.diagnostics_runtime_virtualization_value', CommonConstants.LIST_PAGE_SIZE))
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.diagnostics_runtime_fps'), this.frameRateValue())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.diagnostics_runtime_indexes'),
        $r('app.string.diagnostics_runtime_indexes_value'))
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  @Builder
  RecordingCard() {
    Column({ space: $r('app.float.space_s') }) {
      Row({ space: $r('app.float.space_s') }) {
        Text($r('app.string.diagnostics_toggle'))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: appSettings.diagnosticsEnabled })
          .selectedColor($r('app.color.hm_brand'))
          .onChange((value: boolean) => {
            appSettings.diagnosticsEnabled = value;
            settingsStore.save();
          })
      }
      .width('100%')
      .height($r('app.float.row_height'))

      Text($r('app.string.diagnostics_toggle_desc'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      Button($r('app.string.diagnostics_clear'))
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_danger'))
        .onClick(() => {
          this.clearRecords();
        })

      Text($r('app.string.diagnostics_privacy'))
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

  build() {
    Scroll(this.scroller) {
      Column() {
        Row().width('100%').height(safeArea.contentTopInsetVp)

        Text($r('app.string.diagnostics_desc'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .padding({ top: $r('app.float.space_s') })

        this.SectionTitle($r('app.string.diagnostics_section_startup'))
        this.StartupCard()

        this.SectionTitle($r('app.string.diagnostics_section_fetch'))
        this.FetchCard()

        this.SectionTitle($r('app.string.diagnostics_section_failure'))
        this.FailureCard()

        this.SectionTitle($r('app.string.diagnostics_section_slow'))
        this.SlowCard()

        this.SectionTitle($r('app.string.diagnostics_section_health'))
        this.HealthCard()

        this.SectionTitle($r('app.string.diagnostics_section_runtime'))
        this.RuntimeCard()

        this.SectionTitle($r('app.string.diagnostics_section_record'))
        this.RecordingCard()

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
