/*
 * FeedViewModel.ets — 订阅与文章的装配、抓取编排（@ObservedV2）。
 *
 * 数据流：本地库（缓存 + 已读/收藏）是唯一事实来源 —— 冷启动先出缓存列表（离线可读），
 * 再联网抓取并把新条目写回本地库，最后重新读库生成界面列表。已读 / 收藏只写在本地库，
 * 抓取过程不会覆盖（ArticleStore.insertNew 只做 INSERT OR IGNORE）。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Article, EffectiveFeedSettings, FeedGroup, FeedListItem, FeedSettingsPatch, FeedSource } from '../model/Feed';
import { BatchResult, FeedPreview, PreviewItem } from '../model/FeedPreview';
import {
  feedStore,
  normalizeFeedFullTextMode,
  normalizeFeedInterval,
  normalizeFeedRetention,
  normalizeFeedTriState
} from '../service/FeedStore';
import { feedService, FeedFetchResult, ResolvedFeed } from '../service/FeedService';
import { feedDiscovery } from '../service/FeedDiscovery';
import { articleStore, CacheStats } from '../service/ArticleStore';
import { CommonConstants } from '../common/constants/CommonConstants';
import { UrlText } from '../common/utils/UrlText';
import { ArticleDataSource, ArticleGroup } from './ArticleDataSource';
import { articleContentService } from '../service/ArticleContentService';
import { ParsedArticle, ParsedFeed } from '../service/RssParser';
import { buildOpml, OpmlEntry } from '../service/OpmlCodec';
import { toArticles } from '../service/ArticleMapper';
import { GroupMode, ArticleFilter, FeedError, FeedFetchError, ReaderState } from '../common/constants/RssConstants';
import { appSettings } from '../model/AppSettings';
import { ArchiveDays, AutoRefreshMinutes, FullTextMode, TriState } from '../common/constants/SettingsConstants';
import { settingsStore } from '../service/SettingsStore';
import { settingsViewModel } from './SettingsViewModel';
import { retentionService } from '../service/RetentionService';
import { remoteSyncService } from '../service/remote/RemoteSyncService';

const MINUTE_MS: number = 60 * 1000;

/** 分组头行的占位订阅源（永不渲染）。 */
const PLACEHOLDER_FEED: FeedSource = new FeedSource('', '', '', '');

function describeError(error: BusinessError): string {
  return error.message;
}

/** 从抓取异常里取出分类结果码；非 FeedFetchError 一律按兜底 FETCH_FAILED 处理。 */
function errorCodeOf(err: Object): FeedError {
  return err instanceof FeedFetchError ? err.code : FeedError.FETCH_FAILED;
}

/** 启动时回填正文纯文本的最大条数（一次性迁移用）。 */
const BACKFILL_PLAIN_TEXT_LIMIT: number = 200;

/** 「添加订阅源」预览里展示的最新条数。 */
const PREVIEW_ITEM_LIMIT: number = 3;

/**
 * 把本地库读回的一行并回内存里的旧实例（只改字段，不换对象）。
 *
 * 必须保留对象身份：List 里的 ForEach 键值不变时会复用旧节点，子组件仍然绑定旧对象；
 * 若这里直接换成新对象，之后所有「改属性」的操作（已读 / 收藏 / 进度）都改在新对象上，
 * 界面绑定的旧对象纹丝不动 —— 表现为「收藏、未读、已读状态都不对」。
 *
 * 列表读取是**轻量列**（不含正文），所以空值不能覆盖旧实例里已加载的正文。
 */
function mergeArticle(target: Article, source: Article): void {
  target.feedTitle = source.feedTitle;
  target.title = source.title;
  target.link = source.link;
  target.summary = source.summary;
  if (source.content.length > 0) {
    target.content = source.content;
  }
  // contentHtml / readerHtml / plainText 来自按需加载，空串不能覆盖已加载的正文。
  if (source.contentHtml.length > 0) {
    target.contentHtml = source.contentHtml;
  }
  if (source.readerHtml.length > 0) {
    target.readerHtml = source.readerHtml;
    target.readerState = source.readerState;
  } else if (target.readerHtml.length === 0) {
    target.readerState = ReaderState.NONE;
  }
  if (source.plainText.length > 0) {
    target.plainText = source.plainText;
  }
  if (source.pageEtag.length > 0) {
    target.pageEtag = source.pageEtag;
  }
  if (source.pageLastModified.length > 0) {
    target.pageLastModified = source.pageLastModified;
  }
  target.publishedAt = source.publishedAt;
  target.imageUrl = source.imageUrl;
  target.author = source.author;
  target.read = source.read;
  target.starred = source.starred;
  target.saved = source.saved;
  target.progress = source.progress;
  target.progressRatio = source.progressRatio;
}

@ObservedV2
export class FeedViewModel {
  /** 订阅源列表。 */
  @Trace feeds: FeedSource[] = [];
  /** 当前筛选下的文章列表（界面直接渲染这一份）。 */
  @Trace articles: Article[] = [];
  /** 当前筛选：'all' | 'unread' | 'starred'。初值取用户上次的选择。 */
  @Trace filter: string = appSettings.homeFilter;
  /** 列表排序：true = 最新在前（默认），false = 最旧在前。初值取用户上次的选择。 */
  @Trace newestFirst: boolean = appSettings.listNewestFirst;
  /** 当前筛选/排序下的总条数（分页展示用：articles 只是其中已加载的一页）。 */
  @Trace articlesTotal: number = 0;
  /**
   * 列表版本号：每次 publish 自增。
   * LazyForEach 只按键值复用子组件，原地改文章字段（已读 / 收藏等）时数组引用不变，
   * 视图侧据此判断「需要把最新数组重新灌进数据源」；分组视图也用它让组节点重建。
   */
  @Trace articlesRevision: number = 0;
  /** 是否正在抓取。 */
  @Trace loading: boolean = false;
  /** 是否正在批量添加（面板据此显示进度 / 禁用按钮）。 */
  @Trace batchRunning: boolean = false;
  /** 最近一次操作的结果码，视图据此映射文案。 */
  @Trace errorCode: FeedError = FeedError.NONE;
  /** 最近一次成功刷新的时间戳。 */
  @Trace lastUpdated: number = 0;
  /** 未读总数。 */
  @Trace unreadTotal: number = 0;
  /** 当前范围（订阅源 + 关键词）下的未读数，表头展示用。 */
  @Trace unreadShown: number = 0;
  /** 列表分组方式：平铺 / 按订阅源 / 按日期。初值取用户上次的选择。 */
  @Trace groupMode: string = appSettings.listGroupMode;
  /** 分组数据（groupMode !== NONE 时有效；每组自带数据源，组内仍虚拟化）。 */
  @Trace groups: ArticleGroup[] = [];
  /** 是否处于多选模式（长按进入）。 */
  @Trace selecting: boolean = false;
  /** 多选选中的文章 id（数组整体替换，保证 @Trace 能观察到最后一次变更）。 */
  @Trace selectedIds: string[] = [];
  /** 多选锚点（长按的那一行，「以上已读」以它为界）。 */
  @Trace anchorId: string = '';
  /** 已加载条数（分页游标）。 */
  @Trace visibleCount: number = CommonConstants.LIST_PAGE_SIZE;
  /** 单源视图：非空时只看该订阅源的文章。 */
  @Trace scopeFeedId: string = '';
  @Trace scopeTitle: string = '';
  /** 单源文章列表页：当前查看的订阅源 id / 标题。 */
  @Trace detailFeedId: string = '';
  @Trace detailFeedTitle: string = '';
  /** 单源文章列表页的数据（按发布时间倒序；升/降序由视图本地切换）。 */
  @Trace feedArticles: Article[] = [];
  /** 当前打开的文章 id（详情页用）。@Trace：详情页在原文内切换文章时需驱动重渲染。 */
  @Trace currentArticleId: string = '';
  /** 打开详情页后要定位到的标注 id（标注聚合页点进来时用；详情页消费后清空）。 */
  @Trace pendingHighlightId: string = '';
  /** 详情页要定位的检索词（搜索结果点进来时写入；详情页消费后清空）。 */
  @Trace pendingSearchTerm: string = '';
  /** 单源设置页当前查看的订阅源 id。 */
  @Trace settingsFeedId: string = '';

  /** 一天的毫秒数（日期分组用）。 */
  private static readonly DAY_MS: number = 24 * 60 * 60 * 1000;

  /** 全量文章（缓存 + 本次抓取），未读统计与筛选都基于它。 */
  private all: Article[] = [];
  /**
   * 列表内容变化的订阅者（视图用 LazyForEach 时，需要显式把最新数组灌进数据源）。
   * 说明：这里只用 @Trace 属性驱动「直接渲染」的视图；虚拟化列表拿不到这个时机，
   * 所以额外提供显式订阅，避免依赖框架对全局单例的监听行为。
   */
  private articleListeners: Array<() => void> = [];
  private started: boolean = false;
  /** 是否已完成「完整启动装配」（回填 + 联网抓取），避免重复触发。 */
  private initialized: boolean = false;
  /** 最近一次批量抓取中，最后一个失败源的错误码（用于全量失败时上报）。 */
  private lastFailureCode: FeedError = FeedError.FETCH_FAILED;
  /** 宿主上下文（打开库 / 触发后台清理用）。 */
  private context: common.Context | undefined = undefined;
  /** 正文已按需加载的文章 id（列表只读轻量列，正文单独 loadBody）。 */
  private bodyLoaded: Set<string> = new Set<string>();

  /**
   * 轻量装配：订阅源 → 本地缓存（离线可读），**不触发联网抓取**。
   *
   * 供「系统分享」等只需读写订阅 / 文章的入口复用：分享扩展进程里没必要（也不应该）在分享面板
   * 打开的瞬间跑一次全量抓取。幂等，重复调用无副作用。
   */
  async ensureReady(context: common.Context): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    this.context = context;
    // 列表展示偏好（排序 / 分组）是异步从偏好库恢复的，先等它就绪再对齐，
    // 否则首屏会先按默认值渲染一次（换偏好后重启看到顺序被重置）。
    await settingsViewModel.whenReady();
    this.newestFirst = appSettings.listNewestFirst;
    this.groupMode = appSettings.listGroupMode;
    this.filter = appSettings.homeFilter;
    this.feeds = await feedStore.load(context);
    // 远端同步通过回调读写订阅源与文章列表（避免 Service 反向依赖 ViewModel）。
    remoteSyncService.bindFeedSource(
      (): FeedSource[] => this.feeds,
      (feeds: FeedSource[]): void => {
        this.feeds = feeds;
        feedStore.save(this.feeds);
        this.publish();
      },
      (): void => {
        this.reloadAfterRetention().catch((err: BusinessError) => {
          console.warn('remote reload failed: ' + err.message);
        });
      });
    await articleStore.open(context);
    this.all = await articleStore.loadForList();
    retentionService.configure(context, this.feeds);
    this.publish();
  }

  /** 启动装配：订阅源 → 本地缓存（离线可读）→ 联网抓取。 */
  async init(context: common.Context): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    await this.ensureReady(context);
    // 老数据补一次正文纯文本（有上限）：让检索能命中「之前已提取过正文」的那些文章。
    await articleStore.backfillPlainText(BACKFILL_PLAIN_TEXT_LIMIT);
    this.all = await articleStore.loadForList();
    this.publish();
    // 启动时清理超期回收站 + 按节流执行一次保留清理（异步，不阻塞首屏与抓取）。
    this.applyRetentionIfDue();
    // 冷启动是用户动作：force=true 保证首屏能拿到内容（仍不抓停用源）。
    await this.refreshAll(true);
  }

  /**
   * 抓取全部订阅源，写入本地缓存后重新读库。
   * @param force 手动刷新传 true：绕过「源级间隔未到期」，但不绕过「源已停用」。
   */
  async refreshAll(force: boolean = false): Promise<void> {
    if (this.feeds.length === 0) {
      this.all = [];
      this.publish();
      return;
    }
    const targets: FeedSource[] = this.gateFeeds(this.feeds, force);
    if (targets.length === 0) {
      this.loading = false;
      return;
    }
    this.loading = true;
    this.errorCode = FeedError.NONE;
    this.lastFailureCode = FeedError.FETCH_FAILED;
    const fresh: Article[] = [];
    const failed: number = await this.fetchFeeds(targets, fresh);
    await this.commitFresh(fresh);
    if (failed > 0 && failed === targets.length) {
      this.errorCode = this.lastFailureCode;
    }
  }

  /**
   * 抓取门控：只保留「已启用」且「已到抓取间隔」的源。
   * force = true 时绕过到期判断（用户手动下拉 / 点刷新），但停用源仍然跳过。
   */
  private gateFeeds(feeds: FeedSource[], force: boolean): FeedSource[] {
    const result: FeedSource[] = [];
    const now: number = Date.now();
    for (let i = 0; i < feeds.length; i += 1) {
      const feed: FeedSource = feeds[i];
      if (!feed.enabled) {
        continue;
      }
      if (force) {
        result.push(feed);
        continue;
      }
      const minutes: number = this.effectiveSettings(feed.id).intervalMinutes;
      if (minutes <= 0) {
        continue;
      }
      // lastUpdated 是「最近成功时间」；从未成功过（0）视为到期。
      if (feed.lastUpdated <= 0 || now - feed.lastUpdated >= minutes * MINUTE_MS) {
        result.push(feed);
      }
    }
    return result;
  }

  /** 导出当前订阅源为 OPML 文本。 */
  exportOpml(): string {
    return buildOpml(this.feeds);
  }

  /**
   * 导入 OPML 条目：跳过本地已有的地址，其余先入库（用 OPML 里的标题占位）再抓一次。
   * 返回新增数量；只在真正新增时刷新，避免导入重复文件也全量重抓。
   */
  async importFeeds(entries: OpmlEntry[]): Promise<number> {
    const nextFeeds: FeedSource[] = this.feeds.slice();
    const added: FeedSource[] = [];
    for (let i = 0; i < entries.length; i += 1) {
      const entry: OpmlEntry = entries[i];
      if (this.hasUrl(nextFeeds, entry.xmlUrl)) {
        continue;
      }
      const title: string = entry.title.length > 0 ? entry.title : entry.xmlUrl;
      const feed: FeedSource = new FeedSource(entry.xmlUrl, title, entry.xmlUrl, entry.htmlUrl, entry.group);
      nextFeeds.push(feed);
      added.push(feed);
    }
    if (added.length === 0) {
      return 0;
    }
    this.feeds = nextFeeds;
    this.normalizeOrder();
    feedStore.save(this.feeds);
    this.loading = true;
    this.errorCode = FeedError.NONE;
    const fresh: Article[] = [];
    await this.fetchFeeds(added, fresh);
    await this.commitFresh(fresh);
    return added.length;
  }

  /** 逐源抓取；返回失败数量，错误记录在各自 feed.lastError 上，不影响其他源。 */
  private async fetchFeeds(targets: FeedSource[], fresh: Article[]): Promise<number> {
    let failed: number = 0;
    for (let i = 0; i < targets.length; i += 1) {
      const feed: FeedSource = targets[i];
      try {
        const result: FeedFetchResult =
          await feedService.fetchFeed(feed.url, feed.etag, feed.lastModified);
        this.rememberValidators(feed, result.etag, result.lastModified);
        if (result.notModified) {
          // 304：内容没变，连解析都省了（仍算一次成功抓取）。
          console.info('feed not modified (304): ' + feed.url);
          this.markFeedSuccess(feed);
          continue;
        }
        if (result.parsed === undefined) {
          failed += 1;
          this.markFeedFailure(feed, 'document is not a feed', FeedError.PARSE_ERROR);
          continue;
        }
        toArticles(feed, result.parsed, fresh);
        this.markFeedSuccess(feed);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        failed += 1;
        this.markFeedFailure(feed, describeError(error), errorCodeOf(err));
      }
    }
    return failed;
  }

  /** 抓取成功：清空连续失败计数，刷新「最近成功时间」。 */
  private markFeedSuccess(feed: FeedSource): void {
    feed.lastError = '';
    feed.failureCount = 0;
    feed.lastUpdated = Date.now();
  }

  /** 抓取失败：累加连续失败计数，保留错误描述供订阅页 / 源设置页展示。 */
  private markFeedFailure(feed: FeedSource, message: string, code: FeedError): void {
    feed.failureCount = feed.failureCount + 1;
    feed.lastError = message;
    this.lastFailureCode = code;
  }

  /** 记下本次响应的校验值，供下次条件请求（If-None-Match / If-Modified-Since）使用。 */
  private rememberValidators(feed: FeedSource, etag: string, lastModified: string): void {
    feed.etag = etag;
    feed.lastModified = lastModified;
  }

  /**
   * 把本地库读回的数据并回内存列表：同 id 复用旧实例，只更新字段；新 id 才用新对象。
   * 这样界面上已建立的列表项绑定不会被换掉的实例切断（见 mergeArticle 的说明）。
   */
  private async reloadFromStore(): Promise<void> {
    const loaded: Article[] = await articleStore.loadForList();
    const previous: Map<string, Article> = new Map<string, Article>();
    for (let i = 0; i < this.all.length; i += 1) {
      previous.set(this.all[i].id, this.all[i]);
    }
    const merged: Article[] = [];
    for (let i = 0; i < loaded.length; i += 1) {
      const item: Article = loaded[i];
      const kept: Article | undefined = previous.get(item.id);
      if (kept === undefined) {
        merged.push(item);
        // 新行只带了元数据：正文等详情页按需 loadBody。
      } else {
        mergeArticle(kept, item);
        merged.push(kept);
      }
    }
    this.all = merged;
  }

  /** 抓取收尾：新条目入库 → 重新读库 → 重新出列表与未读数。 */
  private async commitFresh(fresh: Article[]): Promise<void> {
    // 新内容入库后回到第一页（否则分页游标停在旧位置、看不到最新）
    this.resetPaging();
    articleStore.insertNew(fresh);
    await this.reloadFromStore();
    this.publish();
    this.lastUpdated = Date.now();
    this.loading = false;
    feedStore.save(this.feeds);
    retentionService.setFeeds(this.feeds);
    // 抓取提交后异步执行保留清理（6 小时节流）：绝不 await，不阻塞界面刷新。
    this.applyRetentionIfDue();
  }

  /**
   * 异步触发保留清理：清理完成后把列表与统计刷新一次（清理走了回收站，索引同步已由 ArticleStore 处理）。
   * 任何失败都只记日志 —— 清理是低优先级后台动作。
   */
  applyRetentionIfDue(): void {
    retentionService.setFeeds(this.feeds);
    retentionService.runIfDue().then((cleaned: number) => {
      if (cleaned > 0) {
        this.reloadAfterRetention();
      }
    }).catch((err: BusinessError) => {
      console.warn('retention run failed: ' + err.message);
    });
  }

  /** 清理 / 恢复 / 重建索引后刷新列表（存储页也会调用）。 */
  async reloadAfterRetention(): Promise<void> {
    await this.reloadFromStore();
    this.publish();
  }

  /**
   * 订阅列表里是否已有该地址（两侧都做归一化，降低「同址不同写法」漏判）。
   * 空地址不算重复。
   */
  private hasUrl(feeds: FeedSource[], url: string): boolean {
    const target: string = UrlText.normalizeUrlInput(url);
    if (target.length === 0) {
      return false;
    }
    for (let i = 0; i < feeds.length; i += 1) {
      if (UrlText.normalizeUrlInput(feeds[i].url) === target) {
        return true;
      }
    }
    return false;
  }

  /** 回到前台时按设置的间隔决定是否自动刷新（首次装配已完成才判断，避免启动时重复抓取）。 */
  maybeAutoRefresh(): void {
    if (this.loading || this.lastUpdated === 0) {
      return;
    }
    const minutes: number = AutoRefreshMinutes.of(appSettings.autoRefresh);
    if (minutes === AutoRefreshMinutes.OFF || this.feeds.length === 0) {
      return;
    }
    const stale: boolean = Date.now() - this.lastUpdated >= minutes * MINUTE_MS;
    if (stale) {
      this.refreshAll();
    }
  }

  /** 切换筛选视图。 */
  setFilter(filter: string): void {
    if (this.filter === filter) {
      return;
    }
    this.filter = filter;
    this.resetPaging();
    appSettings.homeFilter = filter;
    settingsStore.save();
    this.publish();
  }

  /** 进入单源视图。 */
  scopeToFeed(feed: FeedSource): void {
    this.scopeFeedId = feed.id;
    this.scopeTitle = feed.title;
    this.resetPaging();
    this.publish();
  }

  /** 退出单源视图（回到全部订阅源）。 */
  clearScope(): void {
    this.scopeFeedId = '';
    this.scopeTitle = '';
    this.resetPaging();
    this.publish();
  }

  /** 按 id 找订阅源。 */
  private findFeed(feedId: string): FeedSource | undefined {
    for (let i = 0; i < this.feeds.length; i += 1) {
      if (this.feeds[i].id === feedId) {
        return this.feeds[i];
      }
    }
    return undefined;
  }

  /**
   * 只看某个订阅源（文章详情页「只看该源」用）：按 id 定位订阅源并进入单源范围。
   * 找不到（源已被删）时不改变当前范围，返回 false 让调用方决定提示。
   */
  scopeToFeedById(feedId: string): boolean {
    const feed: FeedSource | undefined = this.findFeed(feedId);
    if (feed === undefined) {
      return false;
    }
    this.scopeToFeed(feed);
    return true;
  }

  /**
   * 只刷新当前打开的单源列表页（下拉刷新用）。
   * force = true 时绕过源级间隔（手动刷新），但源已停用时仍然跳过。
   */
  async refreshCurrentFeed(force: boolean = false): Promise<void> {
    const feed: FeedSource | undefined = this.findFeed(this.detailFeedId);
    if (feed === undefined || !feed.enabled) {
      return;
    }
    this.loading = true;
    this.errorCode = FeedError.NONE;
    const fresh: Article[] = [];
    const failed: number = await this.fetchFeeds([feed], fresh);
    await this.commitFresh(fresh);
    if (failed > 0) {
      this.errorCode = this.lastFailureCode;
    }
  }

  /**
   * 文章是否已在内存列表里（纯查询，**不触发任何状态变更**）。
   * 深链消费必须先查再开：openArticle 会 publish，而 publish 又会通知订阅者，
   * 若那时深链 id 还没清空，就会递归进来（真实踩过：无限递归把页面栈搞坏）。
   */
  hasArticle(articleId: string): boolean {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId) {
        return true;
      }
    }
    return false;
  }

  /**
   * 按 id 打开文章（卡片 / 通知深链 / 搜索结果用）：内存里没有时先从库兜底加载。
   * 找不到（例如文章已被清理）时不做任何改变，由调用方决定是否提示。
   */
  async openArticleById(articleId: string): Promise<boolean> {
    const ok: boolean = await this.ensureArticleLoaded(articleId);
    if (!ok) {
      return false;
    }
    this.openArticle(articleId);
    return true;
  }

  /** 确保文章在内存里：不在则按 id 从库加载并并入列表（搜索命中 / 深链兜底）。 */
  async ensureArticleLoaded(articleId: string): Promise<boolean> {
    if (this.findArticle(articleId) !== undefined) {
      return true;
    }
    const loaded: Article | undefined = await articleStore.loadById(articleId);
    if (loaded === undefined) {
      return false;
    }
    this.all.push(loaded);
    this.bodyLoaded.add(articleId);
    this.publish();
    return true;
  }

  /** 按 id 找内存里的文章。 */
  private findArticle(articleId: string): Article | undefined {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId) {
        return this.all[i];
      }
    }
    return undefined;
  }

  /** 按 id 找订阅源（供源设置页 / 视图使用）。 */
  feedById(feedId: string): FeedSource | undefined {
    return this.findFeed(feedId);
  }

  /**
   * 某订阅源的「生效设置」：源级覆盖优先，否则取全局。
   * 视图 / 编排只读这里，避免各处重复写「global 就取全局」。
   */
  effectiveSettings(feedId: string): EffectiveFeedSettings {
    const feed: FeedSource | undefined = this.findFeed(feedId);
    const enabled: boolean = feed === undefined ? true : feed.enabled;
    let interval: number = 0;
    if (feed !== undefined && feed.fetchIntervalMinutes > 0) {
      interval = feed.fetchIntervalMinutes;
    } else {
      const global: number = AutoRefreshMinutes.of(appSettings.autoRefresh);
      interval = global > 0 ? global : 0;
    }
    const fullText: string = feed === undefined || feed.fullTextMode === FullTextMode.GLOBAL
      ? FullTextMode.AUTO
      : feed.fullTextMode;
    const retention: number = retentionService.effectiveRetentionDays(feed);
    let notify: boolean = appSettings.notifyNewArticles;
    if (feed !== undefined) {
      if (feed.notify === TriState.ON) {
        notify = true;
      } else if (feed.notify === TriState.OFF) {
        notify = false;
      }
    }
    let scrollRead: boolean = false;
    if (feed !== undefined) {
      if (feed.markReadOnScroll === TriState.ON) {
        scrollRead = true;
      } else if (feed.markReadOnScroll === TriState.OFF) {
        scrollRead = false;
      }
    }
    return new EffectiveFeedSettings(enabled, interval, fullText, retention, notify, scrollRead);
  }

  /** 「滚动即已读」是否生效（默认关 = 保持「打开即已读」的旧行为）。 */
  markReadOnScrollEffective(feedId: string): boolean {
    return this.effectiveSettings(feedId).markReadOnScroll;
  }

  /** 更新单源设置：归一 → 内存 → 落盘（并同步给保留服务）。 */
  updateFeedSettings(feedId: string, patch: FeedSettingsPatch): void {
    for (let i = 0; i < this.feeds.length; i += 1) {
      const feed: FeedSource = this.feeds[i];
      if (feed.id !== feedId) {
        continue;
      }
      if (patch.enabled !== undefined) {
        feed.enabled = patch.enabled;
      }
      if (patch.fetchIntervalMinutes !== undefined) {
        feed.fetchIntervalMinutes = normalizeFeedInterval(patch.fetchIntervalMinutes);
      }
      if (patch.fullTextMode !== undefined) {
        feed.fullTextMode = normalizeFeedFullTextMode(patch.fullTextMode);
      }
      if (patch.retentionDays !== undefined) {
        feed.retentionDays = normalizeFeedRetention(patch.retentionDays);
      }
      if (patch.notify !== undefined) {
        feed.notify = normalizeFeedTriState(patch.notify);
      }
      if (patch.markReadOnScroll !== undefined) {
        feed.markReadOnScroll = normalizeFeedTriState(patch.markReadOnScroll);
      }
      break;
    }
    feedStore.save(this.feeds);
    retentionService.setFeeds(this.feeds);
    this.publish();
  }

  /** 打开单源设置页（记录目标源 id）。 */
  openFeedSettings(feed: FeedSource): void {
    this.settingsFeedId = feed.id;
  }

  /** 单源设置页标题：源标题（找不到时退回通用标题）。 */
  settingsFeedTitle(): ResourceStr {
    const feed: FeedSource | undefined = this.findFeed(this.settingsFeedId);
    if (feed === undefined || feed.title.length === 0) {
      return $r('app.string.feed_settings_title');
    }
    return feed.title;
  }

  /** 手动重试单个源（源设置页 / 订阅页）：绕过间隔，但停用源不抓。 */
  async retryFeed(feedId: string): Promise<void> {
    const feed: FeedSource | undefined = this.findFeed(feedId);
    if (feed === undefined || !feed.enabled) {
      return;
    }
    this.loading = true;
    this.errorCode = FeedError.NONE;
    const fresh: Article[] = [];
    const failed: number = await this.fetchFeeds([feed], fresh);
    await this.commitFresh(fresh);
    if (failed > 0) {
      this.errorCode = this.lastFailureCode;
    }
  }

  /** 打开单个订阅源的文章列表页：记录目标源并刷新单源列表。 */
  openFeed(feed: FeedSource): void {
    this.detailFeedId = feed.id;
    this.detailFeedTitle = feed.title;
    this.publish();
  }

  /** 取某个订阅源的全部文章（保持 loadRecent 的发布时间倒序）。 */
  private collectFeedArticles(): Article[] {
    const result: Article[] = [];
    if (this.detailFeedId.length === 0) {
      return result;
    }
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].feedId === this.detailFeedId) {
        result.push(this.all[i]);
      }
    }
    return result;
  }

  /** 重命名订阅源：同步更新本地库里的来源名。 */  renameFeed(feedId: string, title: string): void {
    const next: string = title.trim();
    if (next.length === 0) {
      return;
    }
    for (let i = 0; i < this.feeds.length; i += 1) {
      if (this.feeds[i].id === feedId) {
        this.feeds[i].title = next;
        break;
      }
    }
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].feedId === feedId) {
        this.all[i].feedTitle = next;
      }
    }
    if (this.scopeFeedId === feedId) {
      this.scopeTitle = next;
    }
    articleStore.updateFeedTitle(feedId, next);
    feedStore.save(this.feeds);
    this.publish();
  }

  /** 设置订阅源所属分组（空串 = 移出分组）。 */
  setFeedGroup(feedId: string, group: string): void {
    const name: string = group.trim();
    for (let i = 0; i < this.feeds.length; i += 1) {
      if (this.feeds[i].id === feedId) {
        this.feeds[i].group = name;
        break;
      }
    }
    this.normalizeOrder();
    feedStore.save(this.feeds);
  }

  /**
   * 让 feeds 按分组连续排列（分组按首次出现顺序，未分组垫底，组内保持相对顺序）。
   * 顺序即展示顺序，也是「整组拖动」的前提：一组必须是一段连续的区间。
   */
  private normalizeOrder(): void {
    const groups: FeedGroup[] = this.grouped();
    const ordered: FeedSource[] = [];
    for (let i = 0; i < groups.length; i += 1) {
      const bucket: FeedSource[] = groups[i].feeds;
      for (let j = 0; j < bucket.length; j += 1) {
        ordered.push(bucket[j]);
      }
    }
    this.feeds = ordered;
  }

  /** 当前分组顺序（含「未分组」）。 */
  private groupOrder(): string[] {
    const names: string[] = [];
    const groups: FeedGroup[] = this.grouped();
    for (let i = 0; i < groups.length; i += 1) {
      names.push(groups[i].name);
    }
    return names;
  }

  /** 把某个分组整体移动到目标下标处（整组拖动）。 */
  moveGroup(name: string, targetIndex: number): void {
    const names: string[] = this.groupOrder();
    const from: number = names.indexOf(name);
    if (from < 0 || names.length < 2) {
      return;
    }
    const clamped: number = targetIndex < 0 ? 0
      : (targetIndex > names.length - 1 ? names.length - 1 : targetIndex);
    if (clamped === from) {
      return;
    }
    const next: string[] = [];
    for (let i = 0; i < names.length; i += 1) {
      if (i !== from) {
        next.push(names[i]);
      }
    }
    // 移除源分组后，目标下标在 from 之后要左移一位。
    const insertAt: number = clamped > from ? clamped - 1 : clamped;
    next.splice(insertAt, 0, name);

    const buckets: FeedGroup[] = this.grouped();
    const byName: Map<string, FeedSource[]> = new Map<string, FeedSource[]>();
    for (let i = 0; i < buckets.length; i += 1) {
      byName.set(buckets[i].name, buckets[i].feeds);
    }
    const ordered: FeedSource[] = [];
    for (let i = 0; i < next.length; i += 1) {
      const bucket: FeedSource[] | undefined = byName.get(next[i]);
      if (bucket === undefined) {
        continue;
      }
      for (let j = 0; j < bucket.length; j += 1) {
        ordered.push(bucket[j]);
      }
    }
    this.feeds = ordered;
    feedStore.save(this.feeds);
  }

  /**
   * 拖拽落点统一入口：拖分组头 → 整组换位；拖订阅源行 → 单条移动（含跨组）。
   */
  reorderByDrag(fromRow: number, toRow: number): void {
    const rows: FeedListItem[] = this.displayRows();
    if (fromRow < 0 || fromRow >= rows.length || fromRow === toRow) {
      return;
    }
    const source: FeedListItem = rows[fromRow];
    if (!source.isGroup) {
      this.reorderFeed(fromRow, toRow);
      return;
    }
    let targetGroup: string = source.groupName;
    if (toRow >= 0 && toRow < rows.length) {
      targetGroup = rows[toRow].groupName;
    }
    const names: string[] = this.groupOrder();
    const targetIndex: number = names.indexOf(targetGroup);
    if (targetIndex >= 0) {
      this.moveGroup(source.groupName, targetIndex);
    }
  }

  /** 已有分组名（按首次出现顺序去重，不含「未分组」）。 */
  groupNames(): string[] {
    const names: string[] = [];
    for (let i = 0; i < this.feeds.length; i += 1) {
      const name: string = this.feeds[i].group;
      if (name.length === 0 || names.indexOf(name) >= 0) {
        continue;
      }
      names.push(name);
    }
    return names;
  }

  /** 按分组组织订阅源：有分组的按首次出现顺序在前，「未分组」始终垫底。 */
  grouped(): FeedGroup[] {
    const result: FeedGroup[] = [];
    const names: string[] = this.groupNames();
    for (let i = 0; i < names.length; i += 1) {
      const bucket: FeedSource[] = [];
      for (let j = 0; j < this.feeds.length; j += 1) {
        if (this.feeds[j].group === names[i]) {
          bucket.push(this.feeds[j]);
        }
      }
      result.push(new FeedGroup(names[i], bucket));
    }
    const rest: FeedSource[] = [];
    for (let j = 0; j < this.feeds.length; j += 1) {
      if (this.feeds[j].group.length === 0) {
        rest.push(this.feeds[j]);
      }
    }
    if (rest.length > 0 || result.length === 0) {
      result.push(new FeedGroup('', rest));
    }
    return result;
  }

  /** 展平成列表行（分组头 + 该组订阅源），顺序即拖拽/展示顺序。 */
  displayRows(): FeedListItem[] {
    const rows: FeedListItem[] = [];
    const groups: FeedGroup[] = this.grouped();
    for (let i = 0; i < groups.length; i += 1) {
      const group: FeedGroup = groups[i];
      rows.push(new FeedListItem(true, group.name, group.feeds.length, PLACEHOLDER_FEED));
      for (let j = 0; j < group.feeds.length; j += 1) {
        rows.push(new FeedListItem(false, group.name, 0, group.feeds[j]));
      }
    }
    return rows;
  }

  /** 取第 index 行（越界时夹取到边界，拖拽回调里用）。 */
  rowAt(index: number): FeedListItem {
    const rows: FeedListItem[] = this.displayRows();
    if (rows.length === 0) {
      return new FeedListItem(true, '', 0, PLACEHOLDER_FEED);
    }
    if (index < 0) {
      return rows[0];
    }
    if (index >= rows.length) {
      return rows[rows.length - 1];
    }
    return rows[index];
  }

  /**
   * 拖拽落点重排：把 fromRow 的订阅源移动到 toRow 对应位置。
   * 落点是分组头或别的组的订阅源时，会一并把它移到那个分组（落点在末尾则保持原分组追加）。
   */
  reorderFeed(fromRow: number, toRow: number): void {
    const rows: FeedListItem[] = this.displayRows();
    if (fromRow < 0 || fromRow >= rows.length || fromRow === toRow) {
      return;
    }
    const source: FeedListItem = rows[fromRow];
    if (source.isGroup) {
      return;
    }
    const moving: FeedSource = source.feed;

    let targetGroup: string = moving.group;
    let anchor: FeedSource | undefined = undefined;
    if (toRow >= 0 && toRow < rows.length) {
      const target: FeedListItem = rows[toRow];
      if (target.isGroup) {
        targetGroup = target.groupName;
        anchor = this.firstFeedAfter(rows, toRow);
      } else {
        targetGroup = target.feed.group;
        anchor = target.feed;
      }
    }
    if (anchor !== undefined && anchor.id === moving.id) {
      return;
    }

    const remaining: FeedSource[] = [];
    for (let i = 0; i < this.feeds.length; i += 1) {
      if (this.feeds[i].id !== moving.id) {
        remaining.push(this.feeds[i]);
      }
    }
    const ordered: FeedSource[] = [];
    let placed: boolean = false;
    if (anchor === undefined) {
      for (let i = 0; i < remaining.length; i += 1) {
        ordered.push(remaining[i]);
      }
      ordered.push(moving);
    } else {
      for (let i = 0; i < remaining.length; i += 1) {
        if (!placed && remaining[i].id === anchor.id) {
          ordered.push(moving);
          placed = true;
        }
        ordered.push(remaining[i]);
      }
      if (!placed) {
        ordered.push(moving);
      }
    }
    moving.group = targetGroup;
    this.feeds = ordered;
    this.normalizeOrder();
    feedStore.save(this.feeds);
  }

  /** 上移 / 下移（delta = -1 / +1）：只在同分组内换位，越界不动。 */
  moveFeed(feedId: string, delta: number): void {
    let index: number = -1;
    for (let i = 0; i < this.feeds.length; i += 1) {
      if (this.feeds[i].id === feedId) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      return;
    }
    const group: string = this.feeds[index].group;
    let target: number = -1;
    for (let i = index + delta; i >= 0 && i < this.feeds.length; i += delta) {
      if (this.feeds[i].group === group) {
        target = i;
        break;
      }
    }
    if (target < 0) {
      return;
    }
    const next: FeedSource[] = this.feeds.slice();
    const swap: FeedSource = next[index];
    next[index] = next[target];
    next[target] = swap;
    this.feeds = next;
    feedStore.save(this.feeds);
  }

  private firstFeedAfter(rows: FeedListItem[], index: number): FeedSource | undefined {
    for (let i = index + 1; i < rows.length; i += 1) {
      if (!rows[i].isGroup) {
        return rows[i].feed;
      }
    }
    return undefined;
  }

  /**
   * 解析一个地址并组装「添加前预览」（不落库）。
   * 失败（空 / 重复 / 网络 / 不是订阅源）时置 errorCode 并返回 undefined。
   * 恰好 1 个地址时界面走这条路径；批量添加则内部逐项调用它。
   */
  async previewFeed(url: string): Promise<FeedPreview | undefined> {
    const normalized: string = UrlText.normalizeUrlInput(url);
    if (normalized.length === 0) {
      this.errorCode = FeedError.EMPTY_URL;
      return undefined;
    }
    if (this.hasUrl(this.feeds, normalized)) {
      this.errorCode = FeedError.DUPLICATE_URL;
      return undefined;
    }
    this.loading = true;
    try {
      // 可能是 feed 地址，也可能是站点主页 —— 后者要靠自动发现找出真正的 feed。
      const resolved: ResolvedFeed | undefined = await this.resolveFeed(normalized);
      if (resolved === undefined) {
        this.errorCode = FeedError.NOT_A_FEED;
        return undefined;
      }
      // 发现出来的地址可能已经订阅过（用户贴了主页，而该 feed 已在列表里）。
      if (this.hasUrl(this.feeds, resolved.url)) {
        this.errorCode = FeedError.DUPLICATE_URL;
        return undefined;
      }
      const title: string = resolved.parsed.title.length > 0 ? resolved.parsed.title : resolved.url;
      const latest: PreviewItem[] = [];
      const count: number = resolved.parsed.articles.length;
      const limit: number = count < PREVIEW_ITEM_LIMIT ? count : PREVIEW_ITEM_LIMIT;
      for (let i = 0; i < limit; i += 1) {
        const item: ParsedArticle = resolved.parsed.articles[i];
        latest.push(new PreviewItem(item.title, item.publishedAt));
      }
      this.errorCode = FeedError.NONE;
      return new FeedPreview(normalized, resolved.url, title, resolved.parsed.siteUrl, count, latest,
        resolved.parsed, resolved.etag, resolved.lastModified,
        this.duplicateSiteTitleFor(resolved.url, resolved.parsed.siteUrl));
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      this.errorCode = errorCodeOf(err);
      console.error('previewFeed failed: ' + describeError(error));
      return undefined;
    } finally {
      this.loading = false;
    }
  }

  /** 确认预览并落库：title / group 为用户在预览里的选择（title 空则回落 feed 自身标题）。 */
  async commitFeed(preview: FeedPreview, title: string, group: string): Promise<boolean> {
    this.loading = true;
    try {
      const resolved: ResolvedFeed =
        new ResolvedFeed(preview.resolvedUrl, preview.parsed, preview.etag, preview.lastModified);
      return await this.commitResolved(resolved, title, group);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      this.errorCode = errorCodeOf(err);
      console.error('commitFeed failed: ' + describeError(error));
      return false;
    } finally {
      this.loading = false;
    }
  }

  /**
   * 新增订阅源（非交互路径：OPML、批量、后台复用）：解析后按默认标题、未分组落库。
   * 交互式单条添加请改用 previewFeed + commitFeed。
   */
  async addFeed(url: string): Promise<boolean> {
    const preview: FeedPreview | undefined = await this.previewFeed(url);
    if (preview === undefined) {
      return false;
    }
    return await this.commitFeed(preview, '', '');
  }

  /**
   * 批量添加：把多行 / 逗号分隔的输入逐项添加（共享一个分组）。
   * 逐项独立成败，返回汇总；单项失败不会中断整批。
   */
  async addFeeds(text: string, group: string): Promise<BatchResult> {
    const result: BatchResult = new BatchResult();
    const urls: string[] = UrlText.splitUrlLines(text);
    if (urls.length === 0) {
      this.errorCode = FeedError.EMPTY_URL;
      return result;
    }
    this.batchRunning = true;
    try {
      for (let i = 0; i < urls.length; i += 1) {
        const preview: FeedPreview | undefined = await this.previewFeed(urls[i]);
        if (preview === undefined) {
          if (this.errorCode === FeedError.DUPLICATE_URL) {
            result.duplicate += 1;
          } else {
            result.failed += 1;
          }
          continue;
        }
        const ok: boolean = await this.commitFeed(preview, '', group);
        if (ok) {
          result.added += 1;
        } else if (this.errorCode === FeedError.DUPLICATE_URL) {
          result.duplicate += 1;
        } else {
          result.failed += 1;
        }
      }
    } finally {
      this.batchRunning = false;
    }
    return result;
  }

  /**
   * 落库一个已解析的订阅源（previewFeed / addFeed / 未来入口共用）。
   * 自定义标题优先于 feed 自身标题：toArticles 会用 feed 标题回写文章行，因此确认后要把
   * 用户标题再补一次（源与文章行都要改）。
   */
  private async commitResolved(resolved: ResolvedFeed, title: string, group: string): Promise<boolean> {
    if (this.hasUrl(this.feeds, resolved.url)) {
      this.errorCode = FeedError.DUPLICATE_URL;
      return false;
    }
    const customTitle: string = title.trim();
    const fallback: string = resolved.parsed.title.length > 0 ? resolved.parsed.title : resolved.url;
    const initial: string = customTitle.length > 0 ? customTitle : fallback;
    const feed: FeedSource = new FeedSource(resolved.url, initial, resolved.url, resolved.parsed.siteUrl, group.trim());
    this.rememberValidators(feed, resolved.etag, resolved.lastModified);
    const nextFeeds: FeedSource[] = this.feeds.slice();
    nextFeeds.push(feed);
    this.feeds = nextFeeds;
    this.normalizeOrder();
    const fresh: Article[] = [];
    toArticles(feed, resolved.parsed, fresh);
    articleStore.insertNew(fresh);
    // toArticles 可能把 feed 标题改成了 feed 自身标题；用户自定义标题要盖回去（源 + 文章行）。
    if (customTitle.length > 0 && feed.title !== customTitle) {
      feed.title = customTitle;
      articleStore.updateFeedTitle(feed.id, customTitle);
    }
    await this.reloadFromStore();
    this.publish();
    this.errorCode = FeedError.NONE;
    this.lastUpdated = Date.now();
    feedStore.save(this.feeds);
    return true;
  }

  /** 预览时判断是否与已有订阅同站点（疑似重复）；返回那个已有订阅的标题，没有返回空串。 */
  private duplicateSiteTitleFor(resolvedUrl: string, siteUrl: string): string {
    const candidate: string = siteUrl.length > 0 ? siteUrl : resolvedUrl;
    for (let i = 0; i < this.feeds.length; i += 1) {
      const feed: FeedSource = this.feeds[i];
      const other: string = feed.siteUrl.length > 0 ? feed.siteUrl : feed.url;
      if (UrlText.isSameSite(other, candidate)) {
        return feed.title;
      }
    }
    return '';
  }

  /**
   * 把用户输入的地址解析成可订阅的 feed：
   *   1) 先直接当 feed 抓一次（绝大多数情况一次成功）；
   *   2) 抓回来的是 HTML（站点主页）就从页面里找 <link rel="alternate" …> 候选，逐个试。
   * 全部失败返回 undefined，由调用方映射成「该地址不是订阅源」。
   */
  private async resolveFeed(url: string): Promise<ResolvedFeed | undefined> {
    let direct: FeedFetchResult;
    try {
      direct = await feedService.fetchFeed(url);
    } catch (err) {
      // 网络 / 协议类错误原样上抛：让界面显示「网络错误」，而不是误报成「不是订阅源」。
      const error: Error = err as Error;
      throw error;
    }
    if (direct.parsed !== undefined) {
      return new ResolvedFeed(url, direct.parsed, direct.etag, direct.lastModified);
    }
    const candidates: string[] = feedDiscovery.candidateUrls(direct.rawBody, url);
    for (let i = 0; i < candidates.length; i += 1) {
      try {
        const result: FeedFetchResult = await feedService.fetchFeed(candidates[i]);
        if (result.parsed !== undefined) {
          return new ResolvedFeed(candidates[i], result.parsed, result.etag, result.lastModified);
        }
      } catch (err) {
        // 单个候选失败就试下一个；全部试完仍失败才算「不是订阅源」。
        continue;
      }
    }
    return undefined;
  }

  /** 删除订阅源及其文章（含本地缓存）。 */
  removeFeed(feedId: string): void {
    const nextFeeds: FeedSource[] = [];
    for (let i = 0; i < this.feeds.length; i += 1) {
      if (this.feeds[i].id !== feedId) {
        nextFeeds.push(this.feeds[i]);
      }
    }
    const nextAll: Article[] = [];
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].feedId !== feedId) {
        nextAll.push(this.all[i]);
      }
    }
    this.feeds = nextFeeds;
    this.all = nextAll;
    articleStore.deleteByFeed(feedId);
    this.publish();
    feedStore.save(this.feeds);
  }

  /**
   * 替换某个订阅源的地址：保留原标题与分组，删掉旧源与旧文章，再按新地址重建。
   * 地址无法解析 / 已被别的源占用时返回 false（errorCode 由 previewFeed 设置）。
   */
  async replaceFeedUrl(feedId: string, newUrl: string): Promise<boolean> {
    let current: FeedSource | undefined = undefined;
    for (let i = 0; i < this.feeds.length; i += 1) {
      if (this.feeds[i].id === feedId) {
        current = this.feeds[i];
        break;
      }
    }
    if (current === undefined) {
      return false;
    }
    const title: string = current.title;
    const group: string = current.group;
    const preview: FeedPreview | undefined = await this.previewFeed(newUrl);
    if (preview === undefined) {
      return false;
    }
    this.loading = true;
    try {
      this.removeFeed(feedId);
      const resolved: ResolvedFeed =
        new ResolvedFeed(preview.resolvedUrl, preview.parsed, preview.etag, preview.lastModified);
      return await this.commitResolved(resolved, title, group);
    } finally {
      this.loading = false;
    }
  }

  /** 批量：把多个订阅源移动到同一分组（空串 = 移出分组）。 */
  setFeedGroupMany(ids: string[], group: string): void {
    if (ids.length === 0) {
      return;
    }
    const name: string = group.trim();
    const wanted: Set<string> = new Set();
    for (let i = 0; i < ids.length; i += 1) {
      wanted.add(ids[i]);
    }
    for (let i = 0; i < this.feeds.length; i += 1) {
      if (wanted.has(this.feeds[i].id)) {
        this.feeds[i].group = name;
      }
    }
    this.normalizeOrder();
    feedStore.save(this.feeds);
    this.publish();
  }

  /** 批量删除订阅源（含各自的文章）。 */
  removeFeeds(ids: string[]): void {
    for (let i = 0; i < ids.length; i += 1) {
      this.removeFeed(ids[i]);
    }
  }

  /**
   * 打开文章：记录当前 id 并保护它不被保留清理。
   *
   * 已读时机按源设置分流：
   *   滚动已读生效（on）→ 打开不标已读，等详情页滚到 ≥80% / 触底时 markFinished；
   *   否则保持旧行为（打开即已读）。
   */
  openArticle(articleId: string): void {
    this.currentArticleId = articleId;
    retentionService.setProtectedArticle(articleId);
    const article: Article | undefined = this.findArticle(articleId);
    if (article !== undefined && this.markReadOnScrollEffective(article.feedId)) {
      this.publish();
      return;
    }
    this.markRead(articleId);
  }

  /** 收藏 / 取消收藏。 */
  toggleStar(articleId: string): void {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId) {
        const next: boolean = !this.all[i].starred;
        this.all[i].starred = next;
        articleStore.setStarred(articleId, next);
        remoteSyncService.enqueueState(articleId, undefined, next);
        break;
      }
    }
    this.publish();
  }

  /** 稍后读切换（列表左滑 / 批量用）。 */
  toggleSaved(articleId: string): void {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId) {
        const next: boolean = !this.all[i].saved;
        this.all[i].saved = next;
        articleStore.setSaved(articleId, next);
        break;
      }
    }
    this.publish();
  }

  /** 批量：已读 / 未读。 */
  markReadMany(ids: string[], read: boolean): void {
    const wanted: Map<string, boolean> = new Map<string, boolean>();
    for (let i = 0; i < ids.length; i += 1) {
      wanted.set(ids[i], true);
    }
    for (let i = 0; i < this.all.length; i += 1) {
      if (wanted.get(this.all[i].id) === true) {
        this.all[i].read = read;
      }
    }
    articleStore.setReadMany(ids, read);
    for (let i = 0; i < ids.length; i += 1) {
      remoteSyncService.enqueueState(ids[i], read, undefined);
    }
    this.exitSelect();
    this.publish();
  }

  /** 批量：收藏。 */
  markStarredMany(ids: string[], starred: boolean): void {
    const wanted: Map<string, boolean> = new Map<string, boolean>();
    for (let i = 0; i < ids.length; i += 1) {
      wanted.set(ids[i], true);
    }
    for (let i = 0; i < this.all.length; i += 1) {
      if (wanted.get(this.all[i].id) === true) {
        this.all[i].starred = starred;
      }
    }
    articleStore.setStarredMany(ids, starred);
    for (let i = 0; i < ids.length; i += 1) {
      remoteSyncService.enqueueState(ids[i], undefined, starred);
    }
    this.exitSelect();
    this.publish();
  }

  /** 批量：稍后读。 */
  markSavedMany(ids: string[], saved: boolean): void {
    const wanted: Map<string, boolean> = new Map<string, boolean>();
    for (let i = 0; i < ids.length; i += 1) {
      wanted.set(ids[i], true);
    }
    for (let i = 0; i < this.all.length; i += 1) {
      if (wanted.get(this.all[i].id) === true) {
        this.all[i].saved = saved;
      }
    }
    articleStore.setSavedMany(ids, saved);
    this.exitSelect();
    this.publish();
  }

  /** 批量：删除（同时从内存列表移除）。 */
  deleteMany(ids: string[]): void {
    const wanted: Map<string, boolean> = new Map<string, boolean>();
    for (let i = 0; i < ids.length; i += 1) {
      wanted.set(ids[i], true);
    }
    const kept: Article[] = [];
    for (let i = 0; i < this.all.length; i += 1) {
      if (wanted.get(this.all[i].id) !== true) {
        kept.push(this.all[i]);
      }
    }
    this.all = kept;
    articleStore.deleteMany(ids);
    this.exitSelect();
    this.publish();
  }

  /**
   * 标记「此处以上」为已读：锚点行之前的条目（不含锚点自己，用户还要读它）。
   * 依据当前列表顺序判定「以上」，因此分组 / 排序切换后仍符合视觉预期。
   */
  markAboveRead(anchorId: string): void {
    let index: number = -1;
    for (let i = 0; i < this.articles.length; i += 1) {
      if (this.articles[i].id === anchorId) {
        index = i;
        break;
      }
    }
    if (index <= 0) {
      return;
    }
    const above: Article[] = this.articles.slice(0, index);
    const ids: string[] = [];
    for (let i = 0; i < above.length; i += 1) {
      if (!above[i].read) {
        above[i].read = true;
        ids.push(above[i].id);
      }
    }
    if (ids.length > 0) {
      articleStore.setReadMany(ids, true);
      for (let i = 0; i < ids.length; i += 1) {
        remoteSyncService.enqueueState(ids[i], true, undefined);
      }
    }
    this.publish();
  }

  /** 进入多选（长按某行）。 */
  beginSelect(articleId: string): void {
    this.selecting = true;
    this.anchorId = articleId;
    this.selectedIds = this.selectedIds.indexOf(articleId) >= 0 ? this.selectedIds : [articleId];
  }

  /** 多选态下点某行：加入 / 移出选中。 */
  toggleSelect(articleId: string): void {
    if (!this.selecting) {
      return;
    }
    if (this.selectedIds.indexOf(articleId) >= 0) {
      this.selectedIds = this.selectedIds.filter((id: string) => id !== articleId);
    } else {
      this.selectedIds = this.selectedIds.concat([articleId]);
    }
  }

  /** 退出多选。 */
  exitSelect(): void {
    this.selecting = false;
    this.selectedIds = [];
    this.anchorId = '';
  }

  /** 全选当前列表已加载的条目。 */
  selectAllVisible(): void {
    const ids: string[] = [];
    for (let i = 0; i < this.articles.length; i += 1) {
      ids.push(this.articles[i].id);
    }
    this.selectedIds = ids;
  }

  /** 全部标为已读。 */
  markAllRead(): void {
    const changed: string[] = [];
    for (let i = 0; i < this.all.length; i += 1) {
      if (!this.all[i].read) {
        this.all[i].read = true;
        changed.push(this.all[i].id);
      }
    }
    articleStore.markAllRead();
    for (let i = 0; i < changed.length; i += 1) {
      remoteSyncService.enqueueState(changed[i], true, undefined);
    }
    this.publish();
  }

  /** 已读 / 未读切换（列表左滑用）。 */
  toggleRead(articleId: string): void {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId) {
        const next: boolean = !this.all[i].read;
        this.all[i].read = next;
        articleStore.setRead(articleId, next);
        remoteSyncService.enqueueState(articleId, next, undefined);
        break;
      }
    }
    this.publish();
  }

  /**
   * 记录阅读进度（滚动位置，px）。
   * 只在详情页滚动结束 / 离开页面时调用，因此**不触发列表重算**（没有列表读这个字段）。
   */
  saveProgress(articleId: string, progress: number, ratio: number = 0): void {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId) {
        this.all[i].progress = progress;
        this.all[i].progressRatio = ratio;
        break;
      }
    }
    articleStore.setProgress(articleId, progress, ratio);
  }

  /** 正文缓存占用（设置页展示）：条数 + 字符量。 */
  @Trace cachedArticles: number = 0;
  @Trace cachedChars: number = 0;

  /** 刷新缓存占用统计。 */
  async refreshCacheStats(): Promise<void> {
    const stats: CacheStats = await articleStore.cacheStats();
    this.cachedArticles = stats.articles;
    this.cachedChars = stats.bytes;
    this.publish();
  }

  /** 清理未收藏文章的正文缓存，返回清理条数；内存里的正文一并失效。 */
  async clearCachedContent(): Promise<number> {
    const cleared: number = await articleStore.clearCachedContent();
    for (let i = 0; i < this.all.length; i += 1) {
      const item: Article = this.all[i];
      if (!item.starred) {
        item.readerHtml = '';
        item.contentHtml = '';
        item.plainText = '';
        item.readerState = ReaderState.NONE;
      }
    }
    await this.refreshCacheStats();
    return cleared;
  }

  /** 按 id 取当前文章；找不到返回 undefined。 */
  currentArticle(): Article | undefined {
    return this.findArticle(this.currentArticleId);
  }

  /**
   * 打开检索命中：补全正文 → 记录待定位检索词 → 打开详情。
   * 详情页在正文加载完成后消费 pendingSearchTerm（复用页内查找定位首个命中）。
   */
  async openSearchHit(articleId: string, term: string): Promise<boolean> {
    const ok: boolean = await this.ensureArticleLoaded(articleId);
    if (!ok) {
      return false;
    }
    await this.ensureBodyLoaded(articleId);
    this.pendingSearchTerm = term;
    this.openArticle(articleId);
    return true;
  }

  /**
   * 确保文章正文已从库加载（列表只读轻量列）。
   * 返回是否成功（文章不存在 / 库不可用时 false，调用方按「无正文」降级）。
   */
  async ensureBodyLoaded(articleId: string): Promise<boolean> {
    const article: Article | undefined = this.findArticle(articleId);
    if (article === undefined) {
      return false;
    }
    if (this.bodyLoaded.has(articleId)) {
      return true;
    }
    const body = await articleStore.loadBody(articleId);
    if (body === undefined) {
      return false;
    }
    article.content = body.content;
    article.contentHtml = body.contentHtml;
    article.readerHtml = body.readerHtml;
    article.plainText = body.plainText;
    article.pageEtag = body.pageEtag;
    article.pageLastModified = body.pageLastModified;
    if (body.readerHtml.length > 0) {
      article.readerState = ReaderState.READY;
    }
    this.bodyLoaded.add(articleId);
    return true;
  }

  /**
   * 取当前文章的 Reader 正文（缓存优先 / feed 全文 / 联网提取），按源全文策略执行。
   * 详情页只调用这里，不直接依赖 service。失败时抛出错误供界面退网页原文。
   */
  async loadReaderHtml(articleId: string): Promise<string> {
    const article: Article | undefined = this.findArticle(articleId);
    if (article === undefined) {
      return '';
    }
    // 正文是按需加载的：先补齐缓存，否则「离线可读」会退化成重新联网提取。
    await this.ensureBodyLoaded(articleId);
    const mode: string = this.effectiveSettings(article.feedId).fullTextMode;
    return articleContentService.ensureReaderHtml(article, mode);
  }

  /** 清空某篇的 Reader 缓存，迫使下次重新提取（详情页「重新提取」用）。 */
  clearReaderHtml(articleId: string): void {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId) {
        this.all[i].readerHtml = '';
        this.all[i].readerState = ReaderState.NONE;
        this.all[i].plainText = '';
        articleStore.setReaderHtml(articleId, '', '');
        return;
      }
    }
  }

  /**
   * 标记「已读完」（滚动到底）：确保已读，并把阅读进度归零 ——
   * 已读完的文章下次打开从头开始，而不是停在文末。
   */
  markFinished(articleId: string): void {
    this.markRead(articleId);
    this.saveProgress(articleId, 0);
  }

  private markRead(articleId: string): void {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId && !this.all[i].read) {
        this.all[i].read = true;
        articleStore.setRead(articleId, true);
        remoteSyncService.enqueueState(articleId, true, undefined);
        break;
      }
    }
    this.recomputeUnread();
    this.publish();
  }

  /**
   * 依据全量列表重算筛选结果与未读数。
   *
   * 列表是**分页**的：articles 只放已加载的前 visibleCount 条（虚拟化列表 + 触底续页），
   * articlesTotal 是当前筛选/排序下的总条数，界面据此决定是否继续加载。
   */
  private publish(): void {
    const visible: Article[] = [];
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.passesFilter(this.all[i])) {
        visible.push(this.all[i]);
      }
    }
    visible.sort((a: Article, b: Article) => {
      return this.newestFirst ? b.publishedAt - a.publishedAt : a.publishedAt - b.publishedAt;
    });
    this.articlesTotal = visible.length;
    if (this.groupMode === GroupMode.NONE) {
      this.groups = [];
      this.articles = this.visibleCount < visible.length ? visible.slice(0, this.visibleCount) : visible;
    } else {
      // 分组模式不再分页：列表本身已经虚拟化，切成组头视图时也不该被「只加载了 50 条」截断。
      this.articles = visible;
      this.groups = this.buildGroups(visible);
    }
    this.feedArticles = this.collectFeedArticles();
    this.recomputeUnread();
    this.articlesRevision += 1;
    for (let i = 0; i < this.articleListeners.length; i += 1) {
      this.articleListeners[i]();
    }
  }

  /** 外部条件（如归档规则）变化后重算列表。 */
  republish(): void {
    this.resetPaging();
    this.publish();
  }

  /** 订阅列表内容变化（组件 aboutToAppear 调用）。 */
  subscribeArticles(listener: () => void): void {
    if (this.articleListeners.indexOf(listener) < 0) {
      this.articleListeners.push(listener);
    }
  }

  /** 退订列表内容变化（组件 aboutToDisappear 调用）。 */
  unsubscribeArticles(listener: () => void): void {
    const index: number = this.articleListeners.indexOf(listener);
    if (index >= 0) {
      this.articleListeners.splice(index, 1);
    }
  }

  /** 触底续页：多加载一屏（列表用 LazyForEach 虚拟化，不怕条数多）。 */
  loadMore(): void {
    if (this.visibleCount >= this.articlesTotal) {
      return;
    }
    this.visibleCount += CommonConstants.LIST_PAGE_SIZE;
    this.publish();
  }

  /** 还有未加载的条目（界面用来显示「加载更多」尾行）。 */
  hasMore(): boolean {
    return this.groupMode === GroupMode.NONE && this.visibleCount < this.articlesTotal;
  }

  /** 切换排序：最新 / 最旧，并回到第一页。 */
  toggleSort(): void {
    this.setSort(!this.newestFirst);
  }

  /** 设置排序方向（最新在前 / 最旧在前），并记住选择。 */
  setSort(newestFirst: boolean): void {
    this.newestFirst = newestFirst;
    this.visibleCount = CommonConstants.LIST_PAGE_SIZE;
    appSettings.listNewestFirst = newestFirst;
    settingsStore.save();
    this.publish();
  }

  /** 设置分组方式：平铺 / 按订阅源 / 按日期，并记住选择。 */
  setGroupMode(mode: string): void {
    if (this.groupMode === mode) {
      return;
    }
    this.groupMode = mode;
    appSettings.listGroupMode = mode;
    settingsStore.save();
    this.publish();
  }

  /**
   * 把（已筛选并排好序的）列表按当前分组方式切分成组。
   * 组顺序沿用列表顺序：按订阅源时是「出现顺序」，按日期时是「时间顺序」。
   */
  private buildGroups(list: Article[]): ArticleGroup[] {
    const order: string[] = [];
    const buckets: Map<string, Article[]> = new Map<string, Article[]>();
    const titles: Map<string, ResourceStr> = new Map<string, ResourceStr>();
    for (let i = 0; i < list.length; i += 1) {
      const item: Article = list[i];
      const key: string = this.groupMode === GroupMode.FEED
        ? item.feedId
        : FeedViewModel.dateBucket(item.publishedAt);
      let bucket: Article[] | undefined = buckets.get(key);
      if (bucket === undefined) {
        bucket = [];
        buckets.set(key, bucket);
        order.push(key);
        titles.set(key, this.groupMode === GroupMode.FEED
          ? item.feedTitle
          : FeedViewModel.dateBucketTitle(key));
      }
      bucket.push(item);
    }

    const result: ArticleGroup[] = [];
    for (let i = 0; i < order.length; i += 1) {
      const items: Article[] | undefined = buckets.get(order[i]);
      const title: ResourceStr | undefined = titles.get(order[i]);
      if (items === undefined || title === undefined) {
        continue;
      }
      let unread: number = 0;
      for (let j = 0; j < items.length; j += 1) {
        if (!items[j].read) {
          unread += 1;
        }
      }
      const source: ArticleDataSource = new ArticleDataSource();
      source.setItems(items);
      result.push(new ArticleGroup(order[i], title, unread, items.length, source));
    }
    return result;
  }

  /** 日期桶：今天 / 昨天 / 本周 / 更早（以周一为一周之始）。 */
  private static dateBucket(ts: number): string {
    const today: number = FeedViewModel.startOfDay(Date.now());
    if (ts >= today) {
      return 'today';
    }
    if (ts >= today - FeedViewModel.DAY_MS) {
      return 'yesterday';
    }
    const weekday: number = (new Date(today).getDay() + 6) % 7;
    if (ts >= today - weekday * FeedViewModel.DAY_MS) {
      return 'this_week';
    }
    return 'earlier';
  }

  /** 时间戳所在自然日的 00:00。 */
  private static startOfDay(ts: number): number {
    const d: Date = new Date(ts);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  /** 日期桶标题。 */
  private static dateBucketTitle(key: string): ResourceStr {
    if (key === 'today') {
      return $r('app.string.group_today');
    }
    if (key === 'yesterday') {
      return $r('app.string.group_yesterday');
    }
    if (key === 'this_week') {
      return $r('app.string.group_this_week');
    }
    return $r('app.string.group_earlier');
  }

  /** 回到第一页（筛选 / 关键词 / 范围 / 刷新后调用）。 */
  resetPaging(): void {
    this.visibleCount = CommonConstants.LIST_PAGE_SIZE;
  }

  /** 单条是否落在当前范围（订阅源 + 筛选 + 关键词）内。 */
  private passesFilter(item: Article): boolean {
    if (this.scopeFeedId.length > 0 && item.feedId !== this.scopeFeedId) {
      return false;
    }
    if (this.filter === ArticleFilter.ARCHIVED) {
      return this.isArchived(item);
    }
    // 归档的文章只在「归档」里出现；其余视图一律排除（否则规则形同虚设）。
    if (this.isArchived(item)) {
      return false;
    }
    if (this.filter === ArticleFilter.UNREAD && item.read) {
      return false;
    }
    if (this.filter === ArticleFilter.STARRED && !item.starred) {
      return false;
    }
    if (this.filter === ArticleFilter.SAVED && !item.saved) {
      return false;
    }
    return true;
  }

  /**
   * 是否已归档：已读、且发布时间超过「归档规则」的天数。
   * 稍后读（saved）永远不归档 —— 用户明确标记要留着的东西不该自己消失。
   * 发布时间缺失（0）的保守视为不归档。
   */
  private isArchived(item: Article): boolean {
    const days: number = ArchiveDays.of(appSettings.archiveRule);
    if (days <= 0 || item.saved || !item.read || item.publishedAt <= 0) {
      return false;
    }
    return Date.now() - item.publishedAt > days * FeedViewModel.DAY_MS;
  }

  /** 当前筛选下被判为归档的条数（设置页 / 筛选条提示用）。 */
  archivedCount(): number {
    let count: number = 0;
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.isArchived(this.all[i])) {
        count += 1;
      }
    }
    return count;
  }

  /**
   * 详情页导航用的有序列表：当前筛选结果，但**始终包含当前文章**（即使它已因标记已读
   * 从「未读」筛选里消失），这样原地切文时才有锚点。
   */
  private navList(): Article[] {
    const list: Article[] = [];
    for (let i = 0; i < this.all.length; i += 1) {
      const item: Article = this.all[i];
      if (item.id === this.currentArticleId || this.passesFilter(item)) {
        list.push(item);
      }
    }
    return list;
  }

  private indexInNav(list: Article[]): number {
    for (let i = 0; i < list.length; i += 1) {
      if (list[i].id === this.currentArticleId) {
        return i;
      }
    }
    return -1;
  }

  /** 下一篇（列表里更旧的一条）；没有返回空串。 */
  nextArticleId(): string {
    const list: Article[] = this.navList();
    const index: number = this.indexInNav(list);
    return index >= 0 && index + 1 < list.length ? list[index + 1].id : '';
  }

  /** 上一篇（列表里更新的一条）；没有返回空串。 */
  prevArticleId(): string {
    const list: Article[] = this.navList();
    const index: number = this.indexInNav(list);
    return index > 0 ? list[index - 1].id : '';
  }

  /** 下一条未读：先向后找，找不到再从列表开头循环找；没有返回空串。 */
  nextUnreadId(): string {
    const list: Article[] = this.navList();
    const index: number = this.indexInNav(list);
    for (let i = index + 1; i < list.length; i += 1) {
      if (!list[i].read) {
        return list[i].id;
      }
    }
    for (let i = 0; i < index; i += 1) {
      if (!list[i].read) {
        return list[i].id;
      }
    }
    return '';
  }

  private recomputeUnread(): void {
    const counts: Map<string, number> = new Map<string, number>();
    let total: number = 0;
    let shown: number = 0;
    for (let i = 0; i < this.all.length; i += 1) {
      const item: Article = this.all[i];
      if (item.read) {
        continue;
      }
      total += 1;
      if (this.scopeFeedId.length === 0 || item.feedId === this.scopeFeedId) {
        shown += 1;
      }
      const current: number | undefined = counts.get(item.feedId);
      counts.set(item.feedId, (current === undefined ? 0 : current) + 1);
    }
    for (let i = 0; i < this.feeds.length; i += 1) {
      const feed: FeedSource = this.feeds[i];
      const count: number | undefined = counts.get(feed.id);
      feed.unreadCount = count === undefined ? 0 : count;
    }
    this.unreadTotal = total;
    this.unreadShown = shown;
  }

}

/** 全局唯一 ViewModel。 */
export const feedViewModel: FeedViewModel = new FeedViewModel();
