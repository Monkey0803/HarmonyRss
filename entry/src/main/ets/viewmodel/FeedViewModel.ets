/*
 * FeedViewModel.ets — 订阅与文章的装配、抓取编排（@ObservedV2）。
 *
 * 数据流：本地库（缓存 + 已读/收藏）是唯一事实来源 —— 冷启动先出缓存列表（离线可读），
 * 再联网抓取并把新条目写回本地库，最后重新读库生成界面列表。已读 / 收藏只写在本地库，
 * 抓取过程不会覆盖（ArticleStore.insertNew 只做 INSERT OR IGNORE）。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Article, FeedGroup, FeedListItem, FeedSource } from '../model/Feed';
import { feedStore } from '../service/FeedStore';
import { feedService } from '../service/FeedService';
import { articleStore } from '../service/ArticleStore';
import { articleContentService } from '../service/ArticleContentService';
import { ParsedArticle, ParsedFeed } from '../service/RssParser';
import { buildOpml, OpmlEntry } from '../service/OpmlCodec';
import { toArticles } from '../service/ArticleMapper';
import { ArticleFilter, FeedError, FeedFetchError, ReaderState } from '../common/constants/RssConstants';
import { appSettings } from '../model/AppSettings';
import { AutoRefreshMinutes } from '../common/constants/SettingsConstants';

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

/** 关键词匹配：标题 / 摘要 / 正文（关键词已转小写）。 */
function matchesKeyword(article: Article, keyword: string): boolean {
  if (article.title.toLowerCase().indexOf(keyword) >= 0) {
    return true;
  }
  if (article.summary.toLowerCase().indexOf(keyword) >= 0) {
    return true;
  }
  return article.content.toLowerCase().indexOf(keyword) >= 0;
}

@ObservedV2
export class FeedViewModel {
  /** 订阅源列表。 */
  @Trace feeds: FeedSource[] = [];
  /** 当前筛选下的文章列表（界面直接渲染这一份）。 */
  @Trace articles: Article[] = [];
  /** 当前筛选：'all' | 'unread' | 'starred'。 */
  @Trace filter: string = ArticleFilter.ALL;
  /** 是否正在抓取。 */
  @Trace loading: boolean = false;
  /** 最近一次操作的结果码，视图据此映射文案。 */
  @Trace errorCode: FeedError = FeedError.NONE;
  /** 最近一次成功刷新的时间戳。 */
  @Trace lastUpdated: number = 0;
  /** 未读总数。 */
  @Trace unreadTotal: number = 0;
  /** 当前范围（订阅源 + 关键词）下的未读数，表头展示用。 */
  @Trace unreadShown: number = 0;
  /** 搜索关键词（标题 / 摘要 / 正文，大小写不敏感）。 */
  @Trace keyword: string = '';
  /** 单源视图：非空时只看该订阅源的文章。 */
  @Trace scopeFeedId: string = '';
  @Trace scopeTitle: string = '';
  /** 当前打开的文章 id（详情页用）。@Trace：详情页在原文内切换文章时需驱动重渲染。 */
  @Trace currentArticleId: string = '';

  /** 全量文章（缓存 + 本次抓取），未读统计与筛选都基于它。 */
  private all: Article[] = [];
  private started: boolean = false;
  /** 最近一次批量抓取中，最后一个失败源的错误码（用于全量失败时上报）。 */
  private lastFailureCode: FeedError = FeedError.FETCH_FAILED;

  /** 启动装配：订阅源 → 本地缓存（离线可读）→ 联网抓取。 */
  async init(context: common.Context): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    this.feeds = await feedStore.load(context);
    await articleStore.open(context);
    this.all = await articleStore.loadRecent();
    this.publish();
    await this.refreshAll();
  }

  /** 抓取全部订阅源，写入本地缓存后重新读库。 */
  async refreshAll(): Promise<void> {
    if (this.feeds.length === 0) {
      this.all = [];
      this.publish();
      return;
    }
    this.loading = true;
    this.errorCode = FeedError.NONE;
    this.lastFailureCode = FeedError.FETCH_FAILED;
    const fresh: Article[] = [];
    const failed: number = await this.fetchFeeds(this.feeds, fresh);
    await this.commitFresh(fresh);
    if (failed > 0 && failed === this.feeds.length) {
      this.errorCode = this.lastFailureCode;
    }
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
        const parsed: ParsedFeed = await feedService.fetchFeed(feed.url);
        toArticles(feed, parsed, fresh);
        feed.lastError = '';
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        failed += 1;
        feed.lastError = describeError(error);
        this.lastFailureCode = errorCodeOf(err);
      }
    }
    return failed;
  }

  /** 抓取收尾：新条目入库 → 重新读库 → 重新出列表与未读数。 */
  private async commitFresh(fresh: Article[]): Promise<void> {
    articleStore.insertNew(fresh);
    articleStore.prune();
    this.all = await articleStore.loadRecent();
    this.publish();
    this.lastUpdated = Date.now();
    this.loading = false;
    feedStore.save(this.feeds);
  }

  private hasUrl(feeds: FeedSource[], url: string): boolean {
    for (let i = 0; i < feeds.length; i += 1) {
      if (feeds[i].url === url) {
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
    this.publish();
  }

  /** 本地搜索：按标题 / 摘要 / 正文匹配（大小写不敏感）。 */
  setKeyword(text: string): void {
    const next: string = text.trim();
    if (this.keyword === next) {
      return;
    }
    this.keyword = next;
    this.publish();
  }

  /** 进入单源视图。 */
  scopeToFeed(feed: FeedSource): void {
    this.scopeFeedId = feed.id;
    this.scopeTitle = feed.title;
    this.publish();
  }

  /** 退出单源视图（回到全部订阅源）。 */
  clearScope(): void {
    this.scopeFeedId = '';
    this.scopeTitle = '';
    this.publish();
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

  /** 新增订阅源：先抓一次校验可用性，成功才入库。 */
  async addFeed(url: string): Promise<boolean> {
    const trimmed: string = url.trim();
    if (trimmed.length === 0) {
      this.errorCode = FeedError.EMPTY_URL;
      return false;
    }
    for (let i = 0; i < this.feeds.length; i += 1) {
      if (this.feeds[i].url === trimmed) {
        this.errorCode = FeedError.DUPLICATE_URL;
        return false;
      }
    }
    this.loading = true;
    try {
      const parsed: ParsedFeed = await feedService.fetchFeed(trimmed);
      const title: string = parsed.title.length > 0 ? parsed.title : trimmed;
      const feed: FeedSource = new FeedSource(trimmed, title, trimmed, parsed.siteUrl);
      const nextFeeds: FeedSource[] = this.feeds.slice();
      nextFeeds.push(feed);
      this.feeds = nextFeeds;
      const fresh: Article[] = [];
      toArticles(feed, parsed, fresh);
      articleStore.insertNew(fresh);
      this.all = await articleStore.loadRecent();
      this.publish();
      this.errorCode = FeedError.NONE;
      this.lastUpdated = Date.now();
      feedStore.save(this.feeds);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      this.errorCode = errorCodeOf(err);
      console.error('addFeed failed: ' + describeError(error));
      return false;
    } finally {
      this.loading = false;
    }
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

  /** 打开文章：记录当前 id 并标记已读。 */
  openArticle(articleId: string): void {
    this.currentArticleId = articleId;
    this.markRead(articleId);
  }

  /** 收藏 / 取消收藏。 */
  toggleStar(articleId: string): void {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId) {
        const next: boolean = !this.all[i].starred;
        this.all[i].starred = next;
        articleStore.setStarred(articleId, next);
        break;
      }
    }
    this.publish();
  }

  /** 全部标为已读。 */
  markAllRead(): void {
    for (let i = 0; i < this.all.length; i += 1) {
      this.all[i].read = true;
    }
    articleStore.markAllRead();
    this.publish();
  }

  /** 已读 / 未读切换（列表左滑用）。 */
  toggleRead(articleId: string): void {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId) {
        const next: boolean = !this.all[i].read;
        this.all[i].read = next;
        articleStore.setRead(articleId, next);
        break;
      }
    }
    this.publish();
  }

  /**
   * 记录阅读进度（滚动位置，px）。
   * 只在详情页滚动结束 / 离开页面时调用，因此**不触发列表重算**（没有列表读这个字段）。
   */
  saveProgress(articleId: string, progress: number): void {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId) {
        this.all[i].progress = progress;
        break;
      }
    }
    articleStore.setProgress(articleId, progress);
  }

  /** 按 id 取当前文章；找不到返回 undefined。 */
  currentArticle(): Article | undefined {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === this.currentArticleId) {
        return this.all[i];
      }
    }
    return undefined;
  }

  /**
   * 取当前文章的 Reader 正文（缓存优先 / feed 全文 / 联网提取）。
   * 详情页只调用这里，不直接依赖 service。失败时抛出错误供界面退网页原文。
   */
  async loadReaderHtml(articleId: string): Promise<string> {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId) {
        return articleContentService.ensureReaderHtml(this.all[i]);
      }
    }
    return '';
  }

  /** 清空某篇的 Reader 缓存，迫使下次重新提取（详情页「重新提取」用）。 */
  clearReaderHtml(articleId: string): void {
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.all[i].id === articleId) {
        this.all[i].readerHtml = '';
        this.all[i].readerState = ReaderState.NONE;
        articleStore.setReaderHtml(articleId, '');
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
        break;
      }
    }
    this.recomputeUnread();
    this.publish();
  }

  /** 依据全量列表重算筛选结果与未读数。 */
  private publish(): void {
    const visible: Article[] = [];
    for (let i = 0; i < this.all.length; i += 1) {
      if (this.passesFilter(this.all[i])) {
        visible.push(this.all[i]);
      }
    }
    this.articles = visible;
    this.recomputeUnread();
  }

  /** 单条是否落在当前范围（订阅源 + 筛选 + 关键词）内。 */
  private passesFilter(item: Article): boolean {
    if (this.scopeFeedId.length > 0 && item.feedId !== this.scopeFeedId) {
      return false;
    }
    if (this.filter === ArticleFilter.UNREAD && item.read) {
      return false;
    }
    if (this.filter === ArticleFilter.STARRED && !item.starred) {
      return false;
    }
    if (this.keyword.length > 0 && !matchesKeyword(item, this.keyword.toLowerCase())) {
      return false;
    }
    return true;
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
