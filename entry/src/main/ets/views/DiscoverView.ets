/*
 * DiscoverView.ets — 「发现与推荐」页（NavDestination 内容，纯状态管理 V2）。
 *
 * 能力：
 *   - 本项目维护的精选目录：分类 / 热门榜 / 关键词筛选，在线更新并回退本地目录；
 *   - 相似源推荐：基于已订阅源的主题标签在本地打分，不联网、不上传订阅列表；
 *   - 网站主页自动发现与预览；RSSHub 路由助手生成候选路由；
 *   - 从剪贴板批量导入书签 / 地址（沿用安全控件授权 + 既有批量校验链路）。
 *
 * 业务逻辑（筛选 / 推荐 / 路由）都在 DiscoverService / RssHubRoutes 纯函数里，本页只做展示与事件上报。
 */

import { DiscoverCategory, DiscoverFeed } from '../model/Discover';
import { displayHost, DiscoverSections, DiscoverService } from '../service/DiscoverService';
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
import { Toast } from '@rss/toast-kit';
import { FeedErrorText } from '../common/utils/FeedErrorText';
import { UrlText } from '../common/utils/UrlText';
import { feedAvatarColor, feedInitial } from '../common/utils/FeedAvatar';
import { clipboardService } from '../service/ClipboardService';
import { discoverCatalogService } from '../service/DiscoverCatalogService';
import { FeedPreview } from '../model/FeedPreview';
import { DateUtil } from '../common/utils/DateUtil';
import { AppSheet } from '../common/components/AppSheet';
import { common } from '@kit.AbilityKit';
import { themePalette } from '../model/ThemePalette';
import { DiscoverSearchField } from './DiscoverSearchField';

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
  /** 正在检测的地址（同一时间只允许一个，避免并发抓取 / 重复提示）。 */
  @Local subscribingUrl: string = '';
  @Local importing: boolean = false;
  /** 「添加订阅源」行是否展开。 */
  @Local addOpen: boolean = false;
  /** 订阅前预览半模态。 */
  @Local previewSheetVisible: boolean = false;
  /** RSSHub 路由助手。 */
  @Local rsshubInput: string = '';
  @Local rsshubBase: string = DEFAULT_RSSHUB_BASE;
  @Local suggestions: RssHubSuggestion[] = [];
  @Local rsshubError: boolean = false;
  @Local websiteInput: string = '';
  @Local checkingWebsite: boolean = false;
  @Local previewTitle: string = '';
  @Local previewCount: number = 0;
  @Local previewChoices: FeedPreview[] = [];
  @Local catalogRevision: number = 0;
  private pendingPreview: FeedPreview | undefined = undefined;

  aboutToAppear(): void {
    this.rsshubBase = normalizeRssHubBase(appSettings.rsshubBase);
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context !== undefined) {
      discoverCatalogService.open(context).then(() => {
        this.catalogRevision = discoverCatalogService.revision;
      });
    }
  }

  aboutToDisappear(): void {
    this.previewSheetVisible = false;
    this.addOpen = false;
  }

  /** 推荐与目录一次算完，保证同一订阅源不会同时出现在两段里。 */
  @Computed
  get sections(): DiscoverSections {
    const revision: number = this.catalogRevision;
    return DiscoverService.sections(this.category, this.keyword, feedViewModel.feeds, 6);
  }

  /** 点击其他控件前先清掉输入焦点，顺带收起软键盘。 */
  private dismissKeyboard(): void {
    this.getUIContext().getFocusController().clearFocus();
  }

  /** 网站主页与 RSSHub 路由都先真实抓取并预览，再由用户确认订阅。 */
  private async inspectAddress(address: string): Promise<void> {
    this.dismissKeyboard();
    if (this.checkingWebsite) {
      return;
    }
    this.checkingWebsite = true;
    this.pendingPreview = undefined;
    this.previewTitle = '';
    this.previewCount = 0;
    this.previewChoices = [];
    const choices: FeedPreview[] = await feedViewModel.previewFeeds(address);
    this.checkingWebsite = false;
    if (choices.length > 0) {
      this.previewChoices = choices;
      this.selectPreview(choices[0]);
      this.previewSheetVisible = true;
      return;
    }
    this.rsshubInput = address;
    this.generateRoutes();
    if (this.suggestions.length === 0) {
      Toast.show($r('app.string.discover_no_feed'));
    }
  }

  private selectPreview(preview: FeedPreview): void {
    this.pendingPreview = preview;
    this.previewTitle = preview.title;
    this.previewCount = preview.itemCount;
  }

  private cancelPreview(): void {
    this.previewSheetVisible = false;
    this.pendingPreview = undefined;
    this.previewTitle = '';
    this.previewCount = 0;
    this.previewChoices = [];
  }

  private async confirmPreview(): Promise<void> {
    const preview: FeedPreview | undefined = this.pendingPreview;
    if (preview === undefined || this.checkingWebsite) {
      return;
    }
    this.checkingWebsite = true;
    const ok: boolean = await feedViewModel.commitFeed(preview, '', '');
    this.checkingWebsite = false;
    if (ok) {
      this.cancelPreview();
      Toast.show($r('app.string.discover_subscribe_success'));
    } else {
      Toast.show(FeedErrorText.of(feedViewModel.errorCode));
    }
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

  /** 目录更新时间存在时才显示副标题；同时读取修订号，目录加载完成后刷新。 */
  private hasCatalogCaption(): boolean {
    const revision: number = this.catalogRevision;
    return discoverCatalogService.updatedAt > 0;
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

  /** 订阅一个地址：点击时才发一次抓取（复用既有 addFeed，含重复检测与错误映射）。 */
  private async subscribeUrl(feedUrl: string): Promise<void> {
    if (this.subscribingUrl.length > 0) {
      return;
    }
    if (this.isSubscribed(feedUrl)) {
      Toast.show($r('app.string.discover_subscribe_duplicate'));
      return;
    }
    this.subscribingUrl = feedUrl;
    try {
      await this.inspectAddress(feedUrl);
    } finally {
      this.subscribingUrl = '';
    }
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
    this.dismissKeyboard();
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
      Toast.show($r('app.string.discover_import_empty'));
      return;
    }
    this.importing = true;
    const result: BatchResult = await feedViewModel.addFeeds(urls.join('\n'), '');
    this.importing = false;
    Toast.show(
      $r('app.string.discover_import_result', result.added, result.duplicate, result.failed));
  }

  @Builder
  CategoryChip(id: string) {
    Text(this.categoryLabel(id))
      .fontSize($r('app.float.font_size_caption'))
      .fontWeight(this.category === id ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.category === id
        ? themePalette.accent()
        : $r('app.color.hm_text_primary'))
      .height($r('app.float.value_chip_height'))
      .padding({
        left: $r('app.float.space_l'),
        right: $r('app.float.space_l')
      })
      .borderRadius($r('app.float.radius_chip'))
      .backgroundColor(this.category === id
        ? $r('app.color.hm_card_background')
        : $r('app.color.hm_page_transparent'))
      .onClick(() => {
        this.dismissKeyboard();
        this.category = id;
      })
  }

  @Builder
  CategoryBar() {
    Stack({ alignContent: Alignment.End }) {
      Scroll() {
        Row({ space: $r('app.float.space_xs') }) {
          ForEach(CHIP_ORDER, (id: string) => {
            this.CategoryChip(id)
          }, (id: string) => id)
        }
        .height('100%')
        .alignItems(VerticalAlign.Center)
        .padding({
          left: $r('app.float.space_xs'),
          right: $r('app.float.space_xs')
        })
      }
      .width('100%')
      .height('100%')
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)

      Row()
        .width($r('app.float.space_3xl'))
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [[$r('app.color.hm_web_surface_clear'), 0.0],
            [$r('app.color.hm_web_surface'), 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height($r('app.float.filter_track_height'))
    .backgroundColor($r('app.color.hm_value_chip_background'))
    .borderRadius($r('app.float.radius_filter_track'))
    .clip(true)
    .margin({ top: $r('app.float.space_m') })
  }

  @Builder
  AddFeedEntry() {
    Column() {
      Row({ space: $r('app.float.space_s') }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([themePalette.accent()])
          .flexShrink(0)
        Text($r('app.string.home_add_feed_title'))
          .fontSize($r('app.float.font_size_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hm_text_primary'))
          .layoutWeight(1)
        SymbolGlyph(this.addOpen ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize($r('app.float.icon_size_tiny'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .flexShrink(0)
      }
      .width('100%')
      .height($r('app.float.tab_item_height'))
      .padding({
        left: $r('app.float.space_l'),
        right: $r('app.float.space_l')
      })
      .onClick(() => {
        this.dismissKeyboard();
        this.addOpen = !this.addOpen;
      })

      if (this.addOpen) {
        Column({ space: $r('app.float.space_s') }) {
          TextInput({ text: this.websiteInput, placeholder: $r('app.string.discover_website_hint') })
            .type(InputType.Normal)
            .fontSize($r('app.float.font_size_body'))
            .height($r('app.float.search_field_height'))
            .backgroundColor($r('app.color.hm_value_chip_background'))
            .borderRadius($r('app.float.radius_search'))
            .onChange((value: string) => {
              this.websiteInput = value;
            })
            .onSubmit(() => {
              this.inspectAddress(this.websiteInput);
            })
          Button(this.checkingWebsite ? $r('app.string.discover_checking') :
            $r('app.string.discover_website_check'))
            .buttonStyle(ButtonStyleMode.NORMAL)
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_on_brand'))
            .backgroundColor(themePalette.fill())
            .width('100%')
            .height($r('app.float.search_field_height'))
            .enabled(!this.checkingWebsite)
            .onClick(() => {
              this.inspectAddress(this.websiteInput);
            })
        }
        .width('100%')
        .padding({
          left: $r('app.float.space_l'),
          right: $r('app.float.space_l'),
          bottom: $r('app.float.space_l')
        })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .margin({ top: $r('app.float.space_m') })
  }

  @Builder
  SectionHeader(title: ResourceStr) {
    Text(title)
      .fontSize($r('app.float.font_size_body'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.hm_text_primary'))
      .width('100%')
      .margin({
        top: $r('app.float.space_2xl'),
        bottom: $r('app.float.space_s')
      })
  }

  @Builder
  RecommendedHeader() {
    Column({ space: $r('app.float.space_xs') }) {
      Text($r('app.string.discover_section_recommended'))
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')
      Text($r('app.string.discover_recommend_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({
      top: $r('app.float.space_2xl'),
      bottom: $r('app.float.space_m')
    })
  }

  @Builder
  CatalogHeader() {
    Column({ space: $r('app.float.space_xs') }) {
      Text(this.sectionTitle())
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')
      if (discoverCatalogService.updatedAt > 0) {
        Text($r('app.string.discover_catalog_updated',
          DateUtil.format(discoverCatalogService.updatedAt)))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({
      top: $r('app.float.space_2xl'),
      bottom: $r('app.float.space_m')
    })
  }

  @Builder
  FeedRow(feed: DiscoverFeed, index: number) {
    Row({ space: $r('app.float.space_m') }) {
      if (this.category === DiscoverCategory.HOT) {
        Text((index + 1).toString())
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width($r('app.float.space_l'))
          .textAlign(TextAlign.Center)
          .flexShrink(0)
      }

      Text(feedInitial(feed.title))
        .fontSize($r('app.float.font_size_section'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_on_brand'))
        .width($r('app.float.discover_avatar_size'))
        .height($r('app.float.discover_avatar_size'))
        .textAlign(TextAlign.Center)
        .borderRadius($r('app.float.subs_avatar_radius'))
        .backgroundColor(feedAvatarColor(feed.title))
        .flexShrink(0)
        .accessibilityLevel('no')

      Column({ space: $r('app.float.space_xxs') }) {
        Text(feed.title)
          .fontSize($r('app.float.font_size_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hm_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: $r('app.float.space_xs') }) {
          Text(displayHost(feed.siteUrl, feed.feedUrl))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          if (this.category === DiscoverCategory.ALL || this.category === DiscoverCategory.HOT) {
            Text('·')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .flexShrink(0)
            Text(this.categoryLabel(feed.category))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .flexShrink(0)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.isSubscribed(feed.feedUrl)) {
        Row({ space: $r('app.float.space_xs') }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize($r('app.float.font_size_section'))
            .fontColor([$r('app.color.hm_text_secondary')])
          Text($r('app.string.discover_subscribed'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
        .flexShrink(0)
      } else {
        Button(this.subscribingUrl === feed.feedUrl
          ? $r('app.string.discover_checking')
          : $r('app.string.discover_subscribe'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(themePalette.accent())
          .backgroundColor(themePalette.tint())
          .height($r('app.float.value_chip_height'))
          .constraintSize({ minWidth: 64 })
          .padding({
            left: $r('app.float.space_m'),
            right: $r('app.float.space_m')
          })
          .enabled(this.subscribingUrl.length === 0)
          .flexShrink(0)
          .accessibilityText($r('app.string.discover_subscribe_a11y', feed.title))
          .onClick(() => {
            this.subscribeUrl(feed.feedUrl);
          })
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_l'),
      right: $r('app.float.space_m'),
      top: $r('app.float.space_m'),
      bottom: $r('app.float.space_m')
    })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  RecommendedList() {
    Column() {
      ForEach(this.sections.recommended, (feed: DiscoverFeed, index: number) => {
        this.FeedRow(feed, index)
        if (index < this.sections.recommended.length - 1) {
          Divider()
            .strokeWidth(1)
            .color($r('app.color.hm_divider'))
            .margin({
              left: $r('app.float.space_l'),
              right: $r('app.float.space_l')
            })
        }
      }, (feed: DiscoverFeed) => feed.feedUrl)
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .clip(true)
  }

  @Builder
  CatalogList() {
    Column() {
      ForEach(this.sections.catalog, (feed: DiscoverFeed, index: number) => {
        this.FeedRow(feed, index)
        if (index < this.sections.catalog.length - 1) {
          Divider()
            .strokeWidth(1)
            .color($r('app.color.hm_divider'))
            .margin({
              left: $r('app.float.space_l'),
              right: $r('app.float.space_l')
            })
        }
      }, (feed: DiscoverFeed) => feed.feedUrl)
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .clip(true)
  }

  @Builder
  EmptyState() {
    Row({ space: $r('app.float.space_s') }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_text_secondary')])
        .flexShrink(0)
      Text($r('app.string.discover_empty'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .layoutWeight(1)
      Button($r('app.string.discover_clear'))
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontSize($r('app.float.font_size_body'))
        .fontColor(themePalette.accent())
        .height($r('app.float.search_field_height'))
        .flexShrink(0)
        .onClick(() => {
          this.dismissKeyboard();
          this.keyword = '';
          this.category = DiscoverCategory.ALL;
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_l'),
      right: $r('app.float.space_l'),
      top: $r('app.float.space_m'),
      bottom: $r('app.float.space_m')
    })
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(VerticalAlign.Center)
  }

  /** 书签 / 剪贴板批量导入（安全控件授权后读一次）。 */
  @Builder
  ImportCard() {
    Column({ space: $r('app.float.space_m') }) {
      Text($r('app.string.discover_import_desc'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: $r('app.float.space_s') }) {
        // 安全控件：用户点击后临时获得剪贴板读取授权（无需 READ_PASTEBOARD 权限）。
        PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE,
          buttonType: ButtonType.Capsule })
          .fontColor($r('app.color.hm_on_brand'))
          .iconColor($r('app.color.hm_on_brand'))
          .backgroundColor(themePalette.fill())
          .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
            this.dismissKeyboard();
            if (this.importing) {
              return;
            }
            if (result !== PasteButtonOnClickResult.SUCCESS) {
              Toast.show($r('app.string.subs_paste_denied'));
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
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding($r('app.float.space_l'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  /** RSSHub 路由助手：实例地址 + 目标地址 + 候选列表。 */
  @Builder
  RssHubCard() {
    Column({ space: $r('app.float.space_m') }) {
      Text($r('app.string.discover_rsshub_desc'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text($r('app.string.discover_rsshub_base'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
      TextInput({ text: this.rsshubBase, placeholder: DEFAULT_RSSHUB_BASE })
        .type(InputType.Normal)
        .fontSize($r('app.float.font_size_body'))
        .height($r('app.float.search_field_height'))
        .backgroundColor($r('app.color.hm_value_chip_background'))
        .borderRadius($r('app.float.radius_search'))
        .onChange((value: string) => {
          this.rsshubBase = value;
        })
        .onSubmit(() => {
          this.persistBase();
        })

      TextInput({ text: this.rsshubInput, placeholder: $r('app.string.discover_rsshub_input_hint') })
        .type(InputType.Normal)
        .fontSize($r('app.float.font_size_body'))
        .height($r('app.float.search_field_height'))
        .backgroundColor($r('app.color.hm_value_chip_background'))
        .borderRadius($r('app.float.radius_search'))
        .onChange((value: string) => {
          this.rsshubInput = value;
        })
        .onSubmit(() => {
          this.generateRoutes();
        })

      Button($r('app.string.discover_rsshub_generate'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .fontSize($r('app.float.font_size_body'))
        .fontColor(themePalette.accent())
        .backgroundColor(themePalette.tint())
        .width('100%')
        .height($r('app.float.search_field_height'))
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
                ? $r('app.string.discover_checking')
                : $r('app.string.discover_subscribe'))
                .buttonStyle(ButtonStyleMode.TEXTUAL)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor(themePalette.accent())
                .height($r('app.float.value_chip_height'))
                .enabled(this.subscribingUrl.length === 0)
                .accessibilityText($r('app.string.discover_subscribe_a11y', item.route))
                .onClick(() => {
                  this.subscribeUrl(item.url);
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
        .padding($r('app.float.space_m'))
        .backgroundColor($r('app.color.hm_value_chip_background'))
        .borderRadius($r('app.float.radius_chip'))
      }, (item: RssHubSuggestion) => item.route)
    }
    .width('100%')
    .padding($r('app.float.space_l'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  PreviewSheet() {
    Column({ space: $r('app.float.space_m') }) {
      Text($r('app.string.subs_preview_title'))
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      if (this.previewChoices.length > 1) {
        Text($r('app.string.subs_choose_feed'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
        Column({ space: $r('app.float.space_xs') }) {
          ForEach(this.previewChoices, (choice: FeedPreview) => {
            Column({ space: $r('app.float.space_xxs') }) {
              Text(choice.title)
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.hm_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(choice.resolvedUrl)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding($r('app.float.space_m'))
            .backgroundColor(this.pendingPreview?.resolvedUrl === choice.resolvedUrl
              ? themePalette.tint()
              : $r('app.color.hm_value_chip_background'))
            .borderRadius($r('app.float.radius_chip'))
            .onClick(() => {
              this.selectPreview(choice);
            })
          }, (choice: FeedPreview) => choice.resolvedUrl)
        }
        .width('100%')
      }

      Text($r('app.string.discover_preview', this.previewTitle, this.previewCount))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      Row({ space: $r('app.float.space_s') }) {
        Button($r('app.string.dialog_cancel'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_secondary'))
          .enabled(!this.checkingWebsite)
          .onClick(() => {
            this.cancelPreview();
          })
        Blank()
        Button(this.checkingWebsite ? $r('app.string.discover_subscribing') :
          $r('app.string.subs_confirm'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor(themePalette.fill())
          .height($r('app.float.search_field_height'))
          .enabled(!this.checkingWebsite && this.previewTitle.length > 0)
          .onClick(() => {
            this.confirmPreview();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding($r('app.float.space_l'))
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll(this.scroller) {
        Column() {
          Row().width('100%').height(safeArea.contentTopInsetVp)

          Text($r('app.string.discover_desc'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .padding({
              top: $r('app.float.space_s'),
              bottom: $r('app.float.space_m')
            })

          DiscoverSearchField({ keyword: this.keyword, onKeyword: (value: string) => { this.keyword = value; } })
          this.CategoryBar()
          this.AddFeedEntry()

          if (this.sections.recommended.length > 0) {
            this.RecommendedHeader()
            this.RecommendedList()
          }

          this.CatalogHeader()
          if (this.sections.catalog.length === 0) {
            this.EmptyState()
          } else {
            this.CatalogList()
          }

          this.SectionHeader($r('app.string.discover_section_import'))
          this.ImportCard()

          this.SectionHeader($r('app.string.discover_section_rsshub'))
          this.RssHubCard()

          Blank().height(safeArea.contentBottomInsetVp + 24)
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

      AppSheet({
        visible: this.previewSheetVisible,
        initialSize: this.previewChoices.length > 1 ? 420 : 300,
        showClose: true,
        onDismiss: () => {
          this.cancelPreview();
        }
      }) {
        this.PreviewSheet()
      }
    }
    .width('100%')
    .height('100%')
  }
}
