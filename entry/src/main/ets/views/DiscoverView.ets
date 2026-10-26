/*
 * DiscoverView.ets — 「发现与推荐」页（NavDestination 内容，纯状态管理 V2）。
 *
 * 能力：
 *   - 本地精选目录：分类 / 热门榜 / 关键词筛选，一键订阅（点击时才抓取一次）；
 *   - 相似源推荐：基于已订阅源的主题标签在本地打分，不联网、不上传订阅列表；
 *   - RSSHub 路由助手：把常见站点 / 个人主页地址推导为候选 RSSHub 路由；
 *   - 从剪贴板批量导入书签 / 地址（沿用安全控件授权 + 既有批量校验链路）。
 *
 * 业务逻辑（筛选 / 推荐 / 路由）都在 DiscoverService / RssHubRoutes 纯函数里，本页只做展示与事件上报。
 */

import { DiscoverCategory, DiscoverFeed } from '../model/Discover';
import { displayHost, DiscoverService } from '../service/DiscoverService';
import {
  DEFAULT_RSSHUB_BASE,
  normalizeRssHubBase,
  RssHubKind,
  RssHubRoutes,
  RssHubSuggestion
} from '../service/RssHubRoutes';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { BatchResult } from '../model/FeedPreview';
import { appSettings } from '../model/AppSettings';
import { settingsStore } from '../service/SettingsStore';
import { safeArea } from '../service/SafeAreaController';
import { ToastUtil } from '../common/utils/ToastUtil';
import { FeedErrorText } from '../common/utils/FeedErrorText';
import { UrlText } from '../common/utils/UrlText';
import { clipboardService } from '../service/ClipboardService';

/** 页面顶部的分类顺序（all / hot 固定在前）。 */
const CHIP_ORDER: string[] = [
  DiscoverCategory.ALL,
  DiscoverCategory.HOT,
  DiscoverCategory.TECH,
  DiscoverCategory.DESIGN,
  DiscoverCategory.BUSINESS,
  DiscoverCategory.SCIENCE,
  DiscoverCategory.INDIE,
  DiscoverCategory.CN
];

@ComponentV2
export struct DiscoverView {
  @Param scroller: Scroller = new Scroller();

  @Local category: string = DiscoverCategory.ALL;
  @Local keyword: string = '';
  /** 正在订阅的地址（同一时间只允许一个，避免并发写库 / 重复提示）。 */
  @Local subscribingUrl: string = '';
  @Local importing: boolean = false;
  /** RSSHub 路由助手。 */
  @Local rsshubInput: string = '';
  @Local rsshubBase: string = DEFAULT_RSSHUB_BASE;
  @Local suggestions: RssHubSuggestion[] = [];
  @Local rsshubError: boolean = false;

  aboutToAppear(): void {
    this.rsshubBase = normalizeRssHubBase(appSettings.rsshubBase);
  }

  /** 当前分类 / 关键词下的目录。 */
  private visibleFeeds(): DiscoverFeed[] {
    return DiscoverService.filter(this.category, this.keyword);
  }

  /** 本地相似源推荐（最多 6 条；没有主题信号时为空）。 */
  private recommendedFeeds(): DiscoverFeed[] {
    return DiscoverService.recommendations(feedViewModel.feeds, 6);
  }

  private isSubscribed(feedUrl: string): boolean {
    return DiscoverService.isSubscribed(feedUrl, feedViewModel.feeds);
  }

  private categoryLabel(id: string): ResourceStr {
    if (id === DiscoverCategory.HOT) {
      return $r('app.string.discover_cat_hot');
    }
    if (id === DiscoverCategory.TECH) {
      return $r('app.string.discover_cat_tech');
    }
    if (id === DiscoverCategory.DESIGN) {
      return $r('app.string.discover_cat_design');
    }
    if (id === DiscoverCategory.BUSINESS) {
      return $r('app.string.discover_cat_business');
    }
    if (id === DiscoverCategory.SCIENCE) {
      return $r('app.string.discover_cat_science');
    }
    if (id === DiscoverCategory.INDIE) {
      return $r('app.string.discover_cat_indie');
    }
    if (id === DiscoverCategory.CN) {
      return $r('app.string.discover_cat_cn');
    }
    return $r('app.string.discover_category_all');
  }

  /** 目录区块标题：热门 / 精选 / 具体主题。 */
  private sectionTitle(): ResourceStr {
    if (this.category === DiscoverCategory.HOT) {
      return $r('app.string.discover_section_popular');
    }
    if (this.category === DiscoverCategory.ALL) {
      return $r('app.string.discover_section_catalog');
    }
    return this.categoryLabel(this.category);
  }

  private rssHubKindLabel(kind: string): ResourceStr {
    if (kind === RssHubKind.GITHUB_COMMITS) {
      return $r('app.string.discover_rsshub_kind_commits');
    }
    if (kind === RssHubKind.GITHUB_RELEASES) {
      return $r('app.string.discover_rsshub_kind_releases');
    }
    if (kind === RssHubKind.GITHUB_ISSUES) {
      return $r('app.string.discover_rsshub_kind_issues');
    }
    if (kind === RssHubKind.BILIBILI_VIDEO) {
      return $r('app.string.discover_rsshub_kind_video');
    }
    if (kind === RssHubKind.BILIBILI_USER) {
      return $r('app.string.discover_rsshub_kind_user_video');
    }
    if (kind === RssHubKind.YOUTUBE_CHANNEL) {
      return $r('app.string.discover_rsshub_kind_channel');
    }
    if (kind === RssHubKind.YOUTUBE_USER) {
      return $r('app.string.discover_rsshub_kind_user');
    }
    if (kind === RssHubKind.TWITTER_USER) {
      return $r('app.string.discover_rsshub_kind_timeline');
    }
    if (kind === RssHubKind.WEIBO_USER) {
      return $r('app.string.discover_rsshub_kind_timeline');
    }
    if (kind === RssHubKind.ZHIHU_USER) {
      return $r('app.string.discover_rsshub_kind_activity');
    }
    if (kind === RssHubKind.JIANSHU_USER) {
      return $r('app.string.discover_rsshub_kind_articles');
    }
    if (kind === RssHubKind.INSTAGRAM_USER) {
      return $r('app.string.discover_rsshub_kind_posts');
    }
    if (kind === RssHubKind.DOUYIN_USER) {
      return $r('app.string.discover_rsshub_kind_video');
    }
    if (kind === RssHubKind.MEDIUM_USER) {
      return $r('app.string.discover_rsshub_kind_articles');
    }
    return $r('app.string.discover_rsshub_kind_route');
  }

  /**
   * 订阅一个地址：点击时才发一次抓取（复用既有 addFeed，含重复检测与错误映射）。
   * title 用于成功提示；RSSHub 候选没有可读标题时传空串。
   */
  private async subscribeUrl(feedUrl: string, title: string): Promise<void> {
    if (this.subscribingUrl.length > 0) {
      return;
    }
    if (this.isSubscribed(feedUrl)) {
      ToastUtil.show(this.getUIContext(), $r('app.string.discover_subscribe_duplicate'));
      return;
    }
    this.subscribingUrl = feedUrl;
    const ok: boolean = await feedViewModel.addFeed(feedUrl);
    this.subscribingUrl = '';
    if (ok) {
      ToastUtil.show(this.getUIContext(),
        title.length > 0
          ? $r('app.string.discover_subscribe_ok', title)
          : $r('app.string.discover_subscribe_success'));
      return;
    }
    ToastUtil.show(this.getUIContext(), FeedErrorText.of(feedViewModel.errorCode));
  }

  /** 归一化并持久化 RSSHub 实例（脏值回退默认实例）。 */
  private persistBase(): void {
    const base: string = normalizeRssHubBase(this.rsshubBase);
    this.rsshubBase = base;
    appSettings.rsshubBase = base;
    settingsStore.save();
  }

  /** 生成 RSSHub 候选：先保存实例（归一化脏值），再按地址推导路由。 */
  private generateRoutes(): void {
    this.persistBase();
    const base: string = this.rsshubBase;

    const input: string = UrlText.normalizeUrlInput(this.rsshubInput);
    if (input.length === 0) {
      this.suggestions = [];
      this.rsshubError = true;
      return;
    }
    const list: RssHubSuggestion[] = RssHubRoutes.suggest(input, base);
    this.suggestions = list;
    this.rsshubError = list.length === 0;
  }

  /** 从剪贴板批量导入：书签 HTML / 纯文本都由 UrlText 提取地址，再逐个校验订阅。 */
  private async importFromClipboard(): Promise<void> {
    if (this.importing) {
      return;
    }
    const text: string = await clipboardService.readText();
    const urls: string[] = UrlText.extractUrls(text);
    if (urls.length === 0) {
      ToastUtil.show(this.getUIContext(), $r('app.string.discover_import_empty'));
      return;
    }
    this.importing = true;
    const result: BatchResult = await feedViewModel.addFeeds(urls.join('\n'), '');
    this.importing = false;
    ToastUtil.show(this.getUIContext(),
      $r('app.string.discover_import_result', result.added, result.duplicate, result.failed));
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
  CategoryChip(id: string) {
    Text(this.categoryLabel(id))
      .fontSize($r('app.float.font_size_caption'))
      .fontColor(this.category === id ? $r('app.color.hm_on_brand') : $r('app.color.hm_text_primary'))
      .padding({
        left: $r('app.float.space_m'),
        right: $r('app.float.space_m'),
        top: $r('app.float.space_s'),
        bottom: $r('app.float.space_s')
      })
      .backgroundColor(this.category === id
        ? $r('app.color.hm_brand')
        : $r('app.color.hm_card_background'))
      .borderRadius($r('app.float.radius_card'))
      .onClick(() => {
        this.category = id;
      })
  }

  @Builder
  FeedCard(feed: DiscoverFeed, rank: number) {
    Row({ space: $r('app.float.space_m') }) {
      if (rank > 0) {
        Text(rank.toString())
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .width(20)
          .textAlign(TextAlign.Center)
      }

      Column({ space: $r('app.float.space_xxs') }) {
        Text(feed.title)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: $r('app.float.space_s') }) {
          Text(displayHost(feed.siteUrl, feed.feedUrl))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.categoryLabel(feed.category))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.isSubscribed(feed.feedUrl)) {
        Text($r('app.string.discover_subscribed'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
      } else {
        Button(this.subscribingUrl === feed.feedUrl
          ? $r('app.string.discover_subscribing')
          : $r('app.string.discover_subscribe'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .height($r('app.float.value_chip_height'))
          .enabled(this.subscribingUrl.length === 0)
          .onClick(() => {
            this.subscribeUrl(feed.feedUrl, feed.title);
          })
      }
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .margin({ bottom: $r('app.float.space_s') })
  }

  /** 顶部搜索 + 分类筛选。 */
  @Builder
  FilterHeader() {
    Column({ space: $r('app.float.space_s') }) {
      TextInput({ text: this.keyword, placeholder: $r('app.string.discover_search_hint') })
        .type(InputType.Normal)
        .fontSize($r('app.float.font_size_body'))
        .height($r('app.float.row_height'))
        .onChange((value: string) => {
          this.keyword = value;
        })

      Scroll() {
        Row({ space: $r('app.float.space_s') }) {
          ForEach(CHIP_ORDER, (id: string) => {
            this.CategoryChip(id)
          }, (id: string) => id)
        }
      }
      .width('100%')
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
    }
    .width('100%')
  }

  /** 书签 / 剪贴板批量导入（安全控件授权后读一次）。 */
  @Builder
  ImportCard() {
    Column({ space: $r('app.float.space_s') }) {
      Text($r('app.string.discover_import_desc'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
      Row({ space: $r('app.float.space_s') }) {
        // 安全控件：用户点击后临时获得剪贴板读取授权（无需 READ_PASTEBOARD 权限）。
        PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE,
          buttonType: ButtonType.Capsule })
          .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
            if (this.importing) {
              return;
            }
            if (result !== PasteButtonOnClickResult.SUCCESS) {
              ToastUtil.show(this.getUIContext(), $r('app.string.subs_paste_denied'));
              return;
            }
            this.importFromClipboard();
          })
        if (this.importing) {
          Text($r('app.string.discover_importing'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
        Blank()
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  /** RSSHub 路由助手：实例地址 + 目标地址 + 候选列表。 */
  @Builder
  RssHubCard() {
    Column({ space: $r('app.float.space_s') }) {
      Text($r('app.string.discover_rsshub_desc'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      Text($r('app.string.discover_rsshub_base'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
      TextInput({ text: this.rsshubBase, placeholder: DEFAULT_RSSHUB_BASE })
        .type(InputType.Normal)
        .fontSize($r('app.float.font_size_body'))
        .onChange((value: string) => {
          this.rsshubBase = value;
        })
        .onSubmit(() => {
          this.persistBase();
        })

      TextInput({ text: this.rsshubInput, placeholder: $r('app.string.discover_rsshub_input_hint') })
        .type(InputType.Normal)
        .fontSize($r('app.float.font_size_body'))
        .onChange((value: string) => {
          this.rsshubInput = value;
        })
        .onSubmit(() => {
          this.generateRoutes();
        })

      Button($r('app.string.discover_rsshub_generate'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_on_brand'))
        .backgroundColor($r('app.color.hm_brand'))
        .width('100%')
        .height($r('app.float.row_height'))
        .onClick(() => {
          this.generateRoutes();
        })

      if (this.rsshubError) {
        Text($r('app.string.discover_rsshub_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .width('100%')
      }

      ForEach(this.suggestions, (item: RssHubSuggestion) => {
        Column({ space: $r('app.float.space_xxs') }) {
          Row({ space: $r('app.float.space_s') }) {
            Text(this.rssHubKindLabel(item.kind))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_primary'))
              .layoutWeight(1)
            if (this.isSubscribed(item.url)) {
              Text($r('app.string.discover_subscribed'))
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_text_secondary'))
            } else {
              Button(this.subscribingUrl === item.url
                ? $r('app.string.discover_subscribing')
                : $r('app.string.discover_subscribe'))
                .buttonStyle(ButtonStyleMode.TEXTUAL)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_brand'))
                .enabled(this.subscribingUrl.length === 0)
                .onClick(() => {
                  this.subscribeUrl(item.url, '');
                })
            }
          }
          .width('100%')
          Text(item.url)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({
          left: $r('app.float.space_s'),
          right: $r('app.float.space_s'),
          top: $r('app.float.space_s'),
          bottom: $r('app.float.space_s')
        })
        .backgroundColor($r('app.color.hm_page_transparent'))
        .borderRadius($r('app.float.radius_card'))
      }, (item: RssHubSuggestion) => item.route)
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

        Text($r('app.string.discover_desc'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .padding({ top: $r('app.float.space_s') })

        this.FilterHeader()

        if (this.category === DiscoverCategory.ALL && this.keyword.trim().length === 0) {
          if (this.recommendedFeeds().length > 0) {
            this.SectionTitle($r('app.string.discover_section_recommended'))
            Text($r('app.string.discover_recommend_hint'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .width('100%')
              .padding({ left: $r('app.float.space_xs'), bottom: $r('app.float.space_s') })
            ForEach(this.recommendedFeeds(), (feed: DiscoverFeed) => {
              this.FeedCard(feed, 0)
            }, (feed: DiscoverFeed) => 'r:' + feed.feedUrl)
          }
        }

        this.SectionTitle(this.sectionTitle())
        if (this.visibleFeeds().length === 0) {
          Text($r('app.string.discover_empty'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .padding($r('app.float.space_l'))
        } else {
          ForEach(this.visibleFeeds(), (feed: DiscoverFeed, index: number) => {
            this.FeedCard(feed, this.category === DiscoverCategory.HOT ? index + 1 : 0)
          }, (feed: DiscoverFeed) => feed.feedUrl)
        }

        this.SectionTitle($r('app.string.discover_section_import'))
        this.ImportCard()

        this.SectionTitle($r('app.string.discover_section_rsshub'))
        this.RssHubCard()

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
