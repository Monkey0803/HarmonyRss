/*
 * RemoteSyncService.ets — 远端同步编排（RemoteBackend：Google Reader API / Feedbin）。
 *
 * 职责：连接 / 登录、订阅合并、文章增量拉取、已读与收藏双向同步、自动同步判断、退出登录。
 * 本地库始终是离线权威副本：所有失败只记录，不破坏本地数据；凭据只走 Asset Store。
 *
 * 纯逻辑辅助（mergeFeeds / decideState / buildEditTagBatches）与副作用分离，便于单测；
 * 具体协议在 GReaderBackend / FeedbinBackend，本类只依赖 RemoteBackend 接口。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ArticleState,
  OutboxItem,
  RemoteAccount,
  RemoteArticle,
  RemoteConnectResult,
  RemoteError,
  RemoteErrorCode,
  RemoteFeed,
  RemoteIdPage,
  RemoteMapping,
  SyncResult,
  SyncStatus
} from '../../model/Remote';
import { Article, FeedSource } from '../../model/Feed';
import { RemoteSyncConstants } from '../../common/constants/RssConstants';
import { buildArticleId } from '../ArticleMapper';
import { ParsedArticle } from '../RssParser';
import { articleStore } from '../ArticleStore';
import { dedupeService } from '../DedupeService';
import { ruleService } from '../RuleService';
import { RuleApplyResult } from '../../model/Rule';
import { remoteAccountStore } from '../RemoteAccountStore';
import { remoteCredentials } from './RemoteCredentials';
import { gReaderBackend } from './GReaderBackend';
import { feedbinBackend } from './FeedbinBackend';
import {
  RemoteArticlePage,
  RemoteBackend,
  RemotePushResult,
  RemoteSession,
  RemoteStateChange
} from './RemoteBackend';
import {
  buildEditTagBatches,
  decideState,
  feedKey,
  FeedMergeResult,
  mergeFeeds
} from './RemoteSyncPlan';
import { appSettings } from '../../model/AppSettings';

const DOMAIN: number = 0x0000;
const TAG: string = 'RemoteSyncService';

/** 纯逻辑在 RemoteSyncPlan 中实现；这里 re-export，保持「同步服务对外提供纯函数」的契约。 */
export { FeedMergeResult, mergeFeeds, decideState, buildEditTagBatches, feedKey };

/** 自动同步间隔（分钟）；off / 脏值为 0。 */
function autoSyncMinutes(value: string): number {
  if (value === RemoteSyncConstants.AUTO_SYNC_15) {
    return 15;
  }
  if (value === RemoteSyncConstants.AUTO_SYNC_30) {
    return 30;
  }
  if (value === RemoteSyncConstants.AUTO_SYNC_60) {
    return 60;
  }
  return 0;
}

/** 远端文章的标题 / 摘要等转成本地 Article（本地 id 与本地抓取一致，天然去重）。 */
function toLocalArticle(feed: FeedSource, item: RemoteArticle): Article {
  const parsedTitle: string = item.title.length > 0
    ? item.title
    : (item.link.length > 0 ? item.link : item.remoteId);
  // 远端文章也走同一套本地 id 规则：feedId + 链接（无链接时用标题）。
  const parsed: ParsedArticle = new ParsedArticle(parsedTitle, item.link, item.summary,
    item.content, item.publishedAt, '', item.author, item.contentHtml);
  const id: string = buildArticleId(feed.id, parsed);
  const article: Article = new Article(id, feed.id, feed.title, parsedTitle, item.link,
    item.summary, item.content, item.publishedAt, '', item.author, item.contentHtml);
  article.read = item.read;
  article.starred = item.starred;
  return article;
}

@ObservedV2
export class RemoteSyncService {
  /** 是否正在同步（账号页按钮禁用 / 进度展示）。 */
  @Trace syncing: boolean = false;
  /** 当前阶段：'idle' | 'feeds' | 'articles' | 'push' | 'pull' | 'done'。 */
  @Trace phase: string = 'idle';
  /** 文章拉取进度：已处理的订阅源数 / 总数。 */
  @Trace progressDone: number = 0;
  @Trace progressTotal: number = 0;
  /** 最近一次失败的错误码（用于账号页即时提示）。 */
  @Trace lastErrorCode: string = '';

  private account: RemoteAccount | undefined = undefined;
  private accountLoaded: boolean = false;
  private session: RemoteSession | undefined = undefined;
  private authAccountId: string = '';
  /** 订阅源读写桥（避免 Service 反向依赖 ViewModel 造成循环导入）。 */
  private feedProvider: (() => FeedSource[]) | undefined = undefined;
  private feedChanged: ((feeds: FeedSource[]) => void) | undefined = undefined;
  private articlesChanged: (() => void) | undefined = undefined;

  /** 按账号持久化的 serviceType 选择后端；未知值保守回退到 GReader。 */
  private backendFor(serviceType: string): RemoteBackend {
    return serviceType === RemoteSyncConstants.SERVICE_TYPE_FEEDBIN ? feedbinBackend : gReaderBackend;
  }

  /** 由 FeedViewModel 注册：读取当前订阅、回写合并结果、刷新文章列表。 */
  bindFeedSource(provider: () => FeedSource[], onFeedsChanged: (feeds: FeedSource[]) => void,
    onArticlesChanged: () => void): void {
    this.feedProvider = provider;
    this.feedChanged = onFeedsChanged;
    this.articlesChanged = onArticlesChanged;
  }

  /** 当前账号（可能为 undefined）。 */
  currentAccount(): RemoteAccount | undefined {
    return this.account;
  }

  /** 立即读一次账号（启动 / 进入账号页时调用）。 */
  async ensureAccount(force: boolean = false): Promise<RemoteAccount | undefined> {
    if (this.accountLoaded && !force) {
      return this.account;
    }
    this.account = await remoteAccountStore.loadAccount();
    this.accountLoaded = true;
    return this.account;
  }

  /**
   * 本地状态变更入队。未连接账号时零开销直接返回。
   * 故意用 void 返回 + fire-and-forget：状态切换不应被数据库写入阻塞。
   */
  enqueueState(articleId: string, read?: boolean, starred?: boolean): void {
    if (articleId.length === 0 || (read === undefined && starred === undefined)) {
      return;
    }
    if (this.accountLoaded && this.account === undefined) {
      return;
    }
    this.ensureAccount().then((account: RemoteAccount | undefined) => {
      if (account === undefined) {
        return;
      }
      remoteAccountStore.enqueueState(articleId, read, starred);
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'enqueue failed: %{public}s', err.message);
    });
  }

  /**
   * 组内状态入队：把「一篇」的状态变化扩散到整组（主条 + 全部重复项）后逐个入队。
   * 组内每篇若各有远端映射，都会各自回写一次，保证远端与本地口径一致（FR-006）。
   * 与 enqueueState 一样 fire-and-forget，不阻塞用户操作。
   */
  enqueueGroupState(articleId: string, read?: boolean, starred?: boolean): void {
    if (articleId.length === 0 || (read === undefined && starred === undefined)) {
      return;
    }
    if (this.accountLoaded && this.account === undefined) {
      return;
    }
    dedupeService.groupIds(articleId).then((ids: string[]) => {
      for (let i = 0; i < ids.length; i += 1) {
        this.enqueueState(ids[i], read, starred);
      }
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'group enqueue failed: %{public}s', err.message);
    });
  }

  /** 连接：URL 归一 → 登录 / 校验 → 存凭据/账号 → 首次同步。 */
  async connect(baseUrl: string, username: string, password: string,
    allowHttp: boolean, serviceType: string = RemoteSyncConstants.SERVICE_TYPE_GREADER): Promise<RemoteConnectResult> {
    const user: string = username.trim();
    if (user.length === 0 || password.length === 0) {
      return new RemoteConnectResult(false, RemoteErrorCode.EMPTY, 'missing fields');
    }
    const backend: RemoteBackend = this.backendFor(serviceType);
    const normalized: string = backend.normalizeBaseUrl(baseUrl);
    if (normalized.length === 0) {
      return new RemoteConnectResult(false, RemoteErrorCode.EMPTY, 'invalid url');
    }
    if (backend.isInsecureUrl(normalized) && !allowHttp) {
      return new RemoteConnectResult(false, RemoteErrorCode.INSECURE_HTTP, 'http not allowed');
    }
    try {
      const session: RemoteSession = await backend.authenticate(normalized, user, password);
      const remoteFeeds: RemoteFeed[] = await backend.listSubscriptions(normalized, session);
      // 复用已有账号 id（更换地址 / 密码时保持映射与游标）。
      const previous: RemoteAccount | undefined = await remoteAccountStore.loadAccount();
      const account: RemoteAccount = previous !== undefined
        ? previous
        : new RemoteAccount(this.newAccountId(), normalized, user, serviceType);
      // 换服务 / 地址时旧映射 / 游标指向另一套协议或服务器，必须清掉，否则会误判增量与回写目标。
      if (previous !== undefined
        && (previous.baseUrl !== normalized || previous.serviceType !== serviceType)) {
        await remoteAccountStore.clearOutbox();
        await remoteAccountStore.clearMappings();
        await remoteAccountStore.clearState();
      }
      account.baseUrl = normalized;
      account.username = user;
      account.serviceType = serviceType;
      account.enabled = true;
      account.failureCount = 0;
      account.lastError = '';
      await remoteCredentials.save(account.id, password);
      await remoteAccountStore.saveAccount(account);
      this.account = account;
      this.accountLoaded = true;
      this.session = session;
      this.authAccountId = account.id;
      const result: RemoteConnectResult =
        new RemoteConnectResult(true, RemoteErrorCode.NONE, '', remoteFeeds.length);
      // 首次同步：失败不影响「已连接」，但把原因带回界面。
      try {
        await this.runSync(account);
      } catch (err) {
        result.syncError = this.codeOf(err);
        hilog.warn(DOMAIN, TAG, 'first sync failed: %{public}s', result.syncError);
      }
      return result;
    } catch (err) {
      const code: RemoteErrorCode = this.codeOfObject(err);
      hilog.warn(DOMAIN, TAG, 'connect failed: %{public}s', code.toString());
      return new RemoteConnectResult(false, code, 'connect failed');
    }
  }

  /** 手动同步。 */
  async syncNow(): Promise<SyncResult> {
    if (this.syncing) {
      throw new RemoteError(RemoteErrorCode.BUSY, 'sync already running');
    }
    const account: RemoteAccount | undefined = await this.ensureAccount();
    if (account === undefined) {
      throw new RemoteError(RemoteErrorCode.NOT_CONNECTED, 'no account');
    }
    return await this.runSync(account);
  }

  /** 同步主流程（push-first：先回写本地变更，再拉远端状态）。 */
  private async runSync(account: RemoteAccount): Promise<SyncResult> {
    this.syncing = true;
    this.lastErrorCode = '';
    this.progressDone = 0;
    this.progressTotal = 0;
    const result: SyncResult = new SyncResult();
    const backend: RemoteBackend = this.backendFor(account.serviceType);
    try {
      const session: RemoteSession = await this.ensureSession(account, backend);
      // 1) 订阅合并
      this.phase = 'feeds';
      const remoteFeeds: RemoteFeed[] = await backend.listSubscriptions(account.baseUrl, session);
      await remoteAccountStore.setState('remote_feed_count', remoteFeeds.length.toString());
      const provider = this.feedProvider;
      const localFeeds: FeedSource[] = provider !== undefined ? provider() : [];
      const merged: FeedMergeResult = mergeFeeds(localFeeds, remoteFeeds);
      result.feedsAdded = merged.added;
      const feedChanged = this.feedChanged;
      if (merged.changed && feedChanged !== undefined) {
        feedChanged(merged.feeds);
      }
      // 2) 文章增量拉取
      this.phase = 'articles';
      this.progressTotal = remoteFeeds.length;
      await this.pullArticles(account, backend, session, remoteFeeds, merged.feeds, result);
      // 3) 回写本地状态（先 push，保证本地最近操作不被远端旧状态覆盖）
      this.phase = 'push';
      await this.pushStates(account, backend, session, result);
      // 4) 拉回远端状态
      this.phase = 'pull';
      await this.pullStates(account, backend, session, result);
      const now: number = Date.now();
      account.lastSyncAt = now;
      account.failureCount = 0;
      account.lastError = '';
      await remoteAccountStore.setState('last_sync_at', now.toString());
      await remoteAccountStore.saveAccount(account);
      this.phase = 'done';
      this.notifyArticlesChanged();
      return result;
    } catch (err) {
      const code: RemoteErrorCode = this.codeOfObject(err);
      // 凭据 / token 失效：清掉内存 session，下次同步重新认证。
      if (code === RemoteErrorCode.AUTH) {
        this.session = undefined;
        this.authAccountId = '';
      }
      this.lastErrorCode = code.toString();
      account.failureCount = account.failureCount + 1;
      account.lastError = code.toString();
      await remoteAccountStore.saveAccount(account);
      this.phase = 'idle';
      throw new RemoteError(code, 'sync failed');
    } finally {
      this.syncing = false;
    }
  }

  private async ensureSession(account: RemoteAccount, backend: RemoteBackend): Promise<RemoteSession> {
    const cached: RemoteSession | undefined = this.session;
    if (cached !== undefined && this.authAccountId === account.id) {
      return cached;
    }
    const password: string | undefined = await remoteCredentials.read(account.id);
    if (password === undefined) {
      throw new RemoteError(RemoteErrorCode.AUTH, 'missing credentials');
    }
    const session: RemoteSession = await backend.authenticate(account.baseUrl, account.username, password);
    this.session = session;
    this.authAccountId = account.id;
    return session;
  }

  /** 拉文章：每源分页，首次只取第一页；重复 remote_id / 重复 link 不重复插入。 */
  private async pullArticles(account: RemoteAccount, backend: RemoteBackend,
    session: RemoteSession, remoteFeeds: RemoteFeed[], localFeeds: FeedSource[],
    result: SyncResult): Promise<void> {
    const remoteByKey: Map<string, RemoteFeed> = new Map<string, RemoteFeed>();
    for (let i = 0; i < remoteFeeds.length; i += 1) {
      const key: string = feedKey(remoteFeeds[i].url);
      if (key.length > 0 && !remoteByKey.has(key)) {
        remoteByKey.set(key, remoteFeeds[i]);
      }
    }
    const seenRemote: Set<string> = new Set<string>();
    let total: number = 0;
    for (let f = 0; f < localFeeds.length; f += 1) {
      const feed: FeedSource = localFeeds[f];
      const remote: RemoteFeed | undefined = remoteByKey.get(feedKey(feed.url));
      if (remote === undefined) {
        this.progressDone = f + 1;
        continue;
      }
      const cursorText: string = await remoteAccountStore.getState('cursor_' + feed.id);
      const articles: Article[] = [];
      const mappings: RemoteMapping[] = [];
      let continuation: string = '';
      let nextCursor: string = cursorText;
      let pages: number = 0;
      const pageLimit: number = cursorText.length === 0 ? 1 : RemoteSyncConstants.MAX_PAGES_PER_FEED;
      while (pages < pageLimit && total < RemoteSyncConstants.MAX_ARTICLES_PER_SYNC) {
        const page: RemoteArticlePage = await backend.fetchArticlePage(account.baseUrl, session,
          remote, cursorText, continuation, RemoteSyncConstants.PAGE_SIZE);
        pages += 1;
        if (page.items.length === 0) {
          break;
        }
        let pageComplete: boolean = true;
        for (let i = 0; i < page.items.length; i += 1) {
          const item: RemoteArticle = page.items[i];
          if (seenRemote.has(item.remoteId)) {
            continue;
          }
          seenRemote.add(item.remoteId);
          const article: Article = toLocalArticle(feed, item);
          articles.push(article);
          mappings.push(new RemoteMapping(item.remoteId, article.id, feed.id));
          total += 1;
          if (total >= RemoteSyncConstants.MAX_ARTICLES_PER_SYNC) {
            // 本页没处理完：不能把游标推进到本页末尾，否则未处理条目会被永久跳过。
            pageComplete = i >= page.items.length - 1;
            break;
          }
        }
        if (pageComplete) {
          nextCursor = backend.betterCursor(nextCursor, page.cursor);
        }
        if (!pageComplete) {
          break;
        }
        if (page.continuation.length === 0) {
          break;
        }
        continuation = page.continuation;
      }
      if (articles.length > 0) {
        const inserted: Article[] = await articleStore.insertRemote(articles, mappings);
        result.articlesAdded += inserted.length;
        // 新入库的远端文章同样执行本地规则；规则失败不影响入库与同步（applyToNew 内部兜底）。
        // 只对真正新增的文章执行：重复同步同一篇不重复计数、不回溯历史文章。
        if (inserted.length > 0) {
          await this.applyRules(inserted);
        }
      }
      if (nextCursor.length > 0 && nextCursor !== cursorText) {
        await remoteAccountStore.setState('cursor_' + feed.id, nextCursor);
      }
      this.progressDone = f + 1;
      if (total >= RemoteSyncConstants.MAX_ARTICLES_PER_SYNC) {
        break;
      }
    }
  }

  /** 回写本地已读 / 收藏：统一的远端变更交给后端批量处理。 */
  private async pushStates(account: RemoteAccount, backend: RemoteBackend,
    session: RemoteSession, result: SyncResult): Promise<void> {
    const pending: OutboxItem[] =
      await remoteAccountStore.pendingItems(RemoteSyncConstants.MAX_ARTICLES_PER_SYNC);
    if (pending.length === 0) {
      return;
    }
    const mappings: RemoteMapping[] = await remoteAccountStore.allMappings();
    const remoteIds: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < mappings.length; i += 1) {
      remoteIds.set(mappings[i].articleId, mappings[i].remoteId);
    }
    const changes: RemoteStateChange[] = [];
    const localIds: string[] = [];
    for (let i = 0; i < pending.length; i += 1) {
      const item: OutboxItem = pending[i];
      const remoteId: string | undefined = remoteIds.get(item.articleId);
      if (remoteId === undefined || (!item.setRead && !item.setStarred)) {
        continue;
      }
      changes.push(new RemoteStateChange(remoteId,
        item.setRead ? item.readValue : undefined,
        item.setStarred ? item.starredValue : undefined));
      localIds.push(item.articleId);
    }
    if (changes.length === 0) {
      // 没有任何可回写的映射 / 变更：直接清掉，避免队列永久积压。
      const orphans: string[] = [];
      for (let i = 0; i < pending.length; i += 1) {
        orphans.push(pending[i].articleId);
      }
      await remoteAccountStore.ackItems(orphans);
      return;
    }
    const pushResult: RemotePushResult =
      await backend.pushStateChanges(account.baseUrl, session, changes);
    for (let i = 0; i < pushResult.errors.length; i += 1) {
      result.errors.push(pushResult.errors[i]);
    }
    const applied: Set<string> = new Set(pushResult.applied);
    const failed: Set<string> = new Set(pushResult.failed);
    const failedText: string = pushResult.errors.length > 0
      ? pushResult.errors[0]
      : RemoteErrorCode.SERVER.toString();
    const acked: string[] = [];
    const attempted: Set<string> = new Set<string>();
    for (let i = 0; i < changes.length; i += 1) {
      const remoteId: string = changes[i].remoteId;
      const localId: string = localIds[i];
      attempted.add(localId);
      if (applied.has(remoteId) && !failed.has(remoteId)) {
        acked.push(localId);
        result.statesPushed += 1;
      } else {
        await remoteAccountStore.failItem(localId, failedText);
      }
    }
    if (acked.length > 0) {
      await remoteAccountStore.ackItems(acked);
    }
    // 没有远端映射 / 没有任何变更的条目：清掉，避免永久重试。
    if (attempted.size < pending.length) {
      const orphans: string[] = [];
      for (let i = 0; i < pending.length; i += 1) {
        if (!attempted.has(pending[i].articleId) && !remoteIds.has(pending[i].articleId)) {
          orphans.push(pending[i].articleId);
        }
      }
      await remoteAccountStore.ackItems(orphans);
    }
  }

  /** 拉回远端已读 / 收藏：只更新状态列，不覆盖正文 / 进度 / 标签。 */
  private async pullStates(account: RemoteAccount, backend: RemoteBackend,
    session: RemoteSession, result: SyncResult): Promise<void> {
    let unreadOk: boolean = true;
    let starredOk: boolean = true;
    let unread: Set<string> = new Set<string>();
    let starred: Set<string> = new Set<string>();
    try {
      unread = await this.collectIds((continuation: string): Promise<RemoteIdPage> => {
        return backend.fetchUnreadIds(account.baseUrl, session, continuation);
      });
    } catch (err) {
      const code: RemoteErrorCode = this.codeOfObject(err);
      if (code === RemoteErrorCode.AUTH) {
        throw new RemoteError(code, 'auth expired during pull');
      }
      unreadOk = false;
      unread = new Set<string>();
      result.errors.push(code.toString());
    }
    try {
      starred = await this.collectIds((continuation: string): Promise<RemoteIdPage> => {
        return backend.fetchStarredIds(account.baseUrl, session, continuation);
      });
    } catch (err) {
      const code: RemoteErrorCode = this.codeOfObject(err);
      if (code === RemoteErrorCode.AUTH) {
        throw new RemoteError(code, 'auth expired during pull');
      }
      starredOk = false;
      starred = new Set<string>();
      result.errors.push(code.toString());
    }
    const mappings: RemoteMapping[] = await remoteAccountStore.allMappings();
    if (mappings.length === 0) {
      return;
    }
    const pendingIds: Set<string> = new Set<string>();
    const pending: OutboxItem[] =
      await remoteAccountStore.pendingItems(RemoteSyncConstants.MAX_ARTICLES_PER_SYNC);
    for (let i = 0; i < pending.length; i += 1) {
      pendingIds.add(pending[i].articleId);
    }
    const ids: string[] = [];
    for (let i = 0; i < mappings.length; i += 1) {
      ids.push(mappings[i].articleId);
    }
    const states: ArticleState[] = await articleStore.loadStates(ids);
    const stateById: Map<string, ArticleState> = new Map<string, ArticleState>();
    for (let i = 0; i < states.length; i += 1) {
      stateById.set(states[i].articleId, states[i]);
    }
    let pulled: number = 0;
    // 决策先全部算完再统一落库：回写是「整组」语义，逐条写会互相覆盖组内状态，
    // 也避免一次同步里做 O(映射数) 次 UPDATE。
    const readTargets: string[] = [];
    const unreadTargets: string[] = [];
    const starredTargets: string[] = [];
    const unstarredTargets: string[] = [];
    for (let i = 0; i < mappings.length; i += 1) {
      const mapping: RemoteMapping = mappings[i];
      const local: ArticleState | undefined = stateById.get(mapping.articleId);
      if (local === undefined) {
        continue;
      }
      const remoteRead: boolean = unreadOk ? !unread.has(mapping.remoteId) : local.read;
      const remoteStarred: boolean = starredOk ? starred.has(mapping.remoteId) : local.starred;
      const decision = decideState(local.read, local.starred, remoteRead, remoteStarred,
        pendingIds.has(mapping.articleId));
      if (decision.read !== local.read) {
        if (decision.read) {
          readTargets.push(mapping.articleId);
        } else {
          unreadTargets.push(mapping.articleId);
        }
        pulled += 1;
      }
      if (decision.starred !== local.starred) {
        if (decision.starred) {
          starredTargets.push(mapping.articleId);
        } else {
          unstarredTargets.push(mapping.articleId);
        }
        pulled += 1;
      }
    }
    // 回写作用到整组：先解析主条 / 重复项再批量落库，保证组内状态一致（FR-006）。
    if (readTargets.length > 0) {
      await dedupeService.applyRead(readTargets, true);
    }
    if (unreadTargets.length > 0) {
      await dedupeService.applyRead(unreadTargets, false);
    }
    if (starredTargets.length > 0) {
      await dedupeService.applyStarred(starredTargets, true);
    }
    if (unstarredTargets.length > 0) {
      await dedupeService.applyStarred(unstarredTargets, false);
    }
    result.statesPulled = pulled;
  }

  /** 分页收集 id（最多 MAX_ID_PAGES 页）。 */
  private async collectIds(fetcher: (continuation: string) => Promise<RemoteIdPage>): Promise<Set<string>> {
    const ids: Set<string> = new Set<string>();
    let continuation: string = '';
    let pages: number = 0;
    while (pages < RemoteSyncConstants.MAX_ID_PAGES) {
      const page: RemoteIdPage = await fetcher(continuation);
      pages += 1;
      for (let i = 0; i < page.ids.length; i += 1) {
        ids.add(page.ids[i]);
      }
      if (page.continuation.length === 0) {
        break;
      }
      continuation = page.continuation;
    }
    return ids;
  }

  /** 退出登录：默认保留本地文章与状态；clearSyncData = true 时清空映射 / 队列 / 游标。 */
  async logout(clearSyncData: boolean): Promise<void> {
    const account: RemoteAccount | undefined = await this.ensureAccount(true);
    if (account !== undefined) {
      await remoteCredentials.remove(account.id);
      if (clearSyncData) {
        await remoteAccountStore.clearOutbox();
        await remoteAccountStore.clearMappings();
        await remoteAccountStore.clearState();
      }
      await remoteAccountStore.clearAccount();
    }
    this.account = undefined;
    this.accountLoaded = true;
    this.session = undefined;
    this.authAccountId = '';
    this.phase = 'idle';
    this.lastErrorCode = '';
  }

  /** 远端订阅数（上次同步时记录；未同步过为 0）。 */
  async remoteFeedCount(): Promise<number> {
    const text: string = await remoteAccountStore.getState('remote_feed_count');
    if (text.length === 0) {
      return 0;
    }
    const value: number = Number.parseInt(text, 10);
    return Number.isNaN(value) ? 0 : value;
  }

  /** 状态快照（账号页展示）。 */
  async status(): Promise<SyncStatus> {
    const account: RemoteAccount | undefined = await this.ensureAccount();
    const pending: number = await remoteAccountStore.pendingCount();
    if (account === undefined) {
      return new SyncStatus(0, pending, 0, '', this.phase);
    }
    return new SyncStatus(account.lastSyncAt, pending, account.failureCount,
      account.lastError, this.phase);
  }

  /** 回前台按设置间隔决定是否自动同步（默认关）。 */
  maybeAutoSync(): void {
    if (this.syncing) {
      return;
    }
    const minutes: number = autoSyncMinutes(appSettings.remoteAutoSync);
    if (minutes <= 0) {
      return;
    }
    this.ensureAccount().then((account: RemoteAccount | undefined) => {
      if (account === undefined) {
        return;
      }
      const stale: boolean = account.lastSyncAt <= 0 ||
        Date.now() - account.lastSyncAt >= minutes * 60 * 1000;
      if (!stale) {
        return;
      }
      this.syncNow().catch((err: Error) => {
        hilog.info(DOMAIN, TAG, 'auto sync failed: %{public}s', err.message);
      });
    }).catch((err: Error) => {
      hilog.info(DOMAIN, TAG, 'auto sync skipped: %{public}s', err.message);
    });
  }

  /**
   * 对刚入库的远端文章执行本地规则，并把规则造成的已读 / 收藏用本类的 enqueueState 入队回写。
   * 刻意不依赖 FeedViewModel（避免循环依赖）；失败只记日志，不影响同步结果。
   */
  private async applyRules(articles: Article[]): Promise<void> {
    if (articles.length === 0) {
      return;
    }
    try {
      const applied: RuleApplyResult = await ruleService.applyToNew(articles);
      for (let i = 0; i < applied.readIds.length; i += 1) {
        this.enqueueGroupState(applied.readIds[i], true, undefined);
      }
      for (let i = 0; i < applied.starredIds.length; i += 1) {
        this.enqueueGroupState(applied.starredIds[i], undefined, true);
      }
    } catch (err) {
      const error: Error = err as Error;
      hilog.warn(DOMAIN, TAG, 'rule apply failed: %{public}s', error.message);
    }
  }

  private notifyArticlesChanged(): void {
    const listener = this.articlesChanged;
    if (listener !== undefined) {
      listener();
    }
  }

  private newAccountId(): string {
    const random: number = Math.floor(Math.random() * 1000000);
    return RemoteSyncConstants.ACCOUNT_ID_PREFIX + Date.now().toString() + '_' + random.toString();
  }

  /** 从任意异常取错误码字符串。 */
  private codeOfObject(err: Object): RemoteErrorCode {
    if (err instanceof RemoteError) {
      return err.code;
    }
    return RemoteErrorCode.SERVER;
  }

  private codeOf(err: Object): string {
    return this.codeOfObject(err).toString();
  }
}

export const remoteSyncService: RemoteSyncService = new RemoteSyncService();
