/*
 * NotifyService.ets — 新文章通知（Model 层：屏蔽通知能力）。
 *
 * 发布路径：
 *   notifyNew          新文章 → 策略过滤 → 免打扰入队 / 立即分组发布
 *   flushQueueIfDue    离开免打扰后把待通知队列合并成一条
 *   maybeSendDigest    每天最多一条「今日摘要」
 *   testNotification   设置页「发送测试通知」
 *
 * 设计要点：
 *   - 每条文章一条通知，`id = stableNotificationId(articleId)`、`groupName = feed_<feedId>`；
 *   - 每源最多 3 条、一次最多 10 条，被限流的部分按源发一条「还有 N 篇」；
 *   - 单条通知带「标记已读 / 收藏」两个动作，点击主体打开文章；
 *   - 任何一步失败只记日志：通知只是锦上添花，不能影响抓取本身。
 */

import { notificationManager } from '@kit.NotificationKit';
import { Article, FeedSource } from '../model/Feed';
import { NotifyItem, NotifyQueueItem, NotifyPolicy } from '../model/Notify';
import { DeepLinkParams } from './DeepLink';
import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommonConstants } from '../common/constants/CommonConstants';
import {
  digestDue,
  filter as filterArticles,
  groupNameOf,
  inDnd,
  localDateKey,
  minutesOfDay,
  plan as planNotifications,
  stableNotificationId
} from './NotifyPolicy';
import { notifyStore } from './NotifyStore';
import { articleStore } from './ArticleStore';
import { feedStore } from './FeedStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'NotifyService';
/** 点击通知要拉起的页面。 */
const MAIN_ABILITY: string = 'EntryAbility';

/** 取错误描述：不假设 err 一定有 code（catch 到的可能是任意对象）。 */
function describeError(err: Object): string {
  const error: BusinessError = err as BusinessError;
  const message: string = error.message;
  return message !== undefined && message.length > 0 ? message : 'unknown error';
}

export class NotifyService {
  /**
   * 系统是否支持 NotificationRequest.groupName。
   * 正常情况恒为 true（API 8+ 均支持）；若带 groupName 的发布失败，
   * 置为 false 并把本次发布降级为「每源一条聚合」，避免整批通知丢失。
   */
  private groupSupported: boolean = true;

  /** 偏好库懒打开：后台任务可能没走设置页初始化，这里保证第一次发布前可用。 */
  private storeReady: Promise<void> = Promise.resolve();
  private storeOpened: boolean = false;

  /** 是否已获得通知授权。 */
  isEnabled(): boolean {
    try {
      return notificationManager.isNotificationEnabledSync();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'isNotificationEnabledSync failed: %{public}s', describeError(err));
      return false;
    }
  }

  /** 首次开启时向用户申请通知授权；返回最终是否可用。 */
  async requestEnable(context: common.UIAbilityContext): Promise<boolean> {
    try {
      if (this.isEnabled()) {
        return true;
      }
      await notificationManager.requestEnableNotification(context);
      return this.isEnabled();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'requestEnable failed: %{public}s', describeError(err));
      return false;
    }
  }

  /** 确保通知偏好库已打开（只打开一次；失败内部已降级，不抛错）。 */
  private async ensureStore(context: common.Context): Promise<void> {
    if (!this.storeOpened) {
      this.storeOpened = true;
      this.storeReady = notifyStore.open(context);
    }
    await this.storeReady;
  }

  /**
   * 新文章通知的统一入口（后台抓取与前台刷新共用）。
   *
   * 1. 未授权 / 没有新增 → 直接返回；
   * 2. 策略过滤（已读 / 隐藏 / 重复 / 源开关 / 关键词）；
   * 3. 免打扰时段 → 文章 id 入队（去重、≤50），不发即时通知；
   * 4. 否则按「每源 3 条、总 10 条」规划并逐条发布；被限流的源补一条聚合。
   */
  async notifyNew(context: common.Context, feeds: FeedSource[], added: Article[]): Promise<void> {
    if (added.length === 0 || !this.isEnabled()) {
      return;
    }
    try {
      await this.ensureStore(context);
      const policy: NotifyPolicy = notifyStore.loadPolicy();
      const filtered: Article[] = filterArticles(added, feeds, policy);
      if (filtered.length === 0) {
        return;
      }
      const now: number = Date.now();
      if (inDnd(policy, minutesOfDay(now))) {
        this.enqueue(filtered, now);
        return;
      }
      if (!this.groupSupported) {
        // 系统不支持分组：降级为「每源一条聚合」。
        await this.publishAggregatesByFeed(context, filtered);
        return;
      }
      const planned = planNotifications(
        filtered, CommonConstants.NOTIFY_MAX_PER_FEED, CommonConstants.NOTIFY_MAX_TOTAL);
      for (let i = 0; i < planned.items.length; i += 1) {
        const ok: boolean = await this.publishItem(context, planned.items[i], true);
        if (!ok && !this.groupSupported) {
          break;
        }
      }
      if (!this.groupSupported) {
        // 逐条发布因分组能力不可用失败 → 改为每源一条聚合（保证信息不丢）。
        await this.publishAggregatesByFeed(context, filtered);
        return;
      }
      await this.publishOverflow(context, planned.overflowByFeed, filtered);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'notifyNew failed: %{public}s', describeError(err));
    }
  }

  /** 免打扰期间入队：追加后交给 saveQueue 统一去重 / 限长。 */
  private enqueue(articles: Article[], at: number): void {
    const queue: NotifyQueueItem[] = notifyStore.loadQueue();
    for (let i = 0; i < articles.length; i += 1) {
      const article: Article = articles[i];
      queue.push(new NotifyQueueItem(article.id, article.feedId, at));
    }
    notifyStore.saveQueue(queue);
  }

  /** 把被限流砍掉的条数按源发一条「还有 N 篇」。 */
  private async publishOverflow(context: common.Context, overflow: Map<string, number>,
    articles: Article[]): Promise<void> {
    const feedIds: string[] = [];
    overflow.forEach((count: number, feedId: string) => {
      if (count > 0) {
        feedIds.push(feedId);
      }
    });
    const titles: Map<string, string> = this.feedTitles(articles);
    const firstIds: Map<string, string> = this.firstArticleIds(articles);
    for (let i = 0; i < feedIds.length; i += 1) {
      const feedId: string = feedIds[i];
      const remaining: number = overflow.get(feedId) ?? 0;
      if (remaining <= 0) {
        continue;
      }
      const feedTitle: string = titles.get(feedId) ?? '';
      const firstArticleId: string = firstIds.get(feedId) ?? '';
      await this.publishAggregate(context, feedTitle, feedId, remaining, firstArticleId);
    }
  }

  /** 分组不可用时的降级：每个源只发一条「N 篇更新」。 */
  private async publishAggregatesByFeed(context: common.Context, articles: Article[]): Promise<void> {
    const counts: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < articles.length; i += 1) {
      const feedId: string = articles[i].feedId;
      counts.set(feedId, (counts.get(feedId) ?? 0) + 1);
    }
    const titles: Map<string, string> = this.feedTitles(articles);
    const firstIds: Map<string, string> = this.firstArticleIds(articles);
    const feedIds: string[] = [];
    counts.forEach((count: number, feedId: string) => {
      if (count > 0) {
        feedIds.push(feedId);
      }
    });
    for (let i = 0; i < feedIds.length; i += 1) {
      const feedId: string = feedIds[i];
      const count: number = counts.get(feedId) ?? 0;
      if (count <= 0) {
        continue;
      }
      await this.publishAggregate(context, titles.get(feedId) ?? '', feedId, count,
        firstIds.get(feedId) ?? '');
    }
  }

  /** feedId → 来源名（取该源第一篇文章的冗余 feedTitle）。 */
  private feedTitles(articles: Article[]): Map<string, string> {
    const titles: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < articles.length; i += 1) {
      if (!titles.has(articles[i].feedId)) {
        titles.set(articles[i].feedId, articles[i].feedTitle);
      }
    }
    return titles;
  }

  /** feedId → 该源第一篇文章 id（聚合通知点击直达用）。 */
  private firstArticleIds(articles: Article[]): Map<string, string> {
    const ids: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < articles.length; i += 1) {
      if (!ids.has(articles[i].feedId)) {
        ids.set(articles[i].feedId, articles[i].id);
      }
    }
    return ids;
  }

  /**
   * 发布单条文章通知。
   * 标题 = 来源名，正文 = 文章标题；actions = true 时带「标记已读 / 收藏」两个按钮。
   */
  async publishItem(context: common.Context, item: NotifyItem, actions: boolean): Promise<boolean> {
    const title: string = item.article.feedTitle.length > 0 ? item.article.feedTitle : item.article.title;
    const text: string = item.article.title.length > 0 ? item.article.title : title;
    return await this.publishNotification(context, item.notificationId, item.groupName,
      title, text, item.article.id, actions);
  }

  /** 每源「还有 N 篇」聚合通知：点击打开该源第一篇文章，不带动作按钮。 */
  async publishAggregate(context: common.Context, feedTitle: string, feedId: string,
    remaining: number, firstArticleId: string): Promise<boolean> {
    try {
      const title: string =
        context.resourceManager.getStringSync($r('app.string.notify_aggregate_title').id);
      const text: string = context.resourceManager.getStringSync(
        $r('app.string.notify_aggregate_text').id, feedTitle, remaining);
      return await this.publishNotification(context,
        stableNotificationId(feedId + ':more'), groupNameOf(feedId),
        title, text, firstArticleId, false);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'publishAggregate failed: %{public}s', describeError(err));
      return false;
    }
  }

  /**
   * 免打扰结束后补发：若已离开免打扰且队列非空，合并成一条通知并清空队列。
   * 点击打开队列里的第一篇文章。
   */
  async flushQueueIfDue(context: common.Context): Promise<void> {
    if (!this.isEnabled()) {
      return;
    }
    try {
      await this.ensureStore(context);
      const policy: NotifyPolicy = notifyStore.loadPolicy();
      const now: number = Date.now();
      if (inDnd(policy, minutesOfDay(now))) {
        return;
      }
      const queue: NotifyQueueItem[] = notifyStore.loadQueue();
      if (queue.length === 0) {
        return;
      }
      const title: string = context.resourceManager.getStringSync(
        $r('app.string.notify_dnd_flush_title').id, queue.length);
      let text: string = '';
      const first: Article | undefined = await articleStore.loadById(queue[0].articleId);
      if (first !== undefined) {
        text = first.title;
      }
      if (text.length === 0) {
        text = context.resourceManager.getStringSync(
          $r('app.string.notify_aggregate_more').id, queue.length);
      }
      const ok: boolean = await this.publishNotification(context,
        stableNotificationId('queue:' + localDateKey(now)), '',
        title, text, queue[0].articleId, false);
      if (ok) {
        notifyStore.saveQueue([]);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'flushQueueIfDue failed: %{public}s', describeError(err));
    }
  }

  /**
   * 每日摘要：开启 + 已到设定小时 + 今天还没发过 → 用当日新文章发一条摘要。
   * 数据源是 articleStore.articlesFetchedSince(当天 00:00)，再走同一套策略过滤。
   */
  async maybeSendDigest(context: common.Context): Promise<void> {
    if (!this.isEnabled()) {
      return;
    }
    try {
      await this.ensureStore(context);
      const policy: NotifyPolicy = notifyStore.loadPolicy();
      const now: number = Date.now();
      if (!digestDue(policy, now, notifyStore.lastDigestDate())) {
        return;
      }
      const dayStart: Date = new Date(now);
      dayStart.setHours(0, 0, 0, 0);
      const articles: Article[] = await articleStore.articlesFetchedSince(dayStart.getTime());
      if (articles.length === 0) {
        return;
      }
      const feeds: FeedSource[] = await feedStore.load(context, false);
      const filtered: Article[] = filterArticles(articles, feeds, policy);
      if (filtered.length === 0) {
        return;
      }
      const title: string = context.resourceManager.getStringSync(
        $r('app.string.notify_digest_notify_title').id, filtered.length);
      let summary: string = this.sourceSummary(filtered);
      if (summary.length === 0) {
        summary = context.resourceManager.getStringSync(
          $r('app.string.notify_aggregate_more').id, filtered.length);
      }
      const text: string = context.resourceManager.getStringSync(
        $r('app.string.notify_digest_notify_text').id, summary);
      const dateKey: string = localDateKey(now);
      const ok: boolean = await this.publishNotification(context,
        stableNotificationId('digest:' + dateKey), '',
        title, text, filtered[0].id, false);
      if (ok) {
        notifyStore.setLastDigestDate(dateKey);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'maybeSendDigest failed: %{public}s', describeError(err));
    }
  }

  /** 设置页「发送测试通知」；返回是否发布成功。 */
  async testNotification(context: common.Context): Promise<boolean> {
    if (!this.isEnabled()) {
      return false;
    }
    try {
      const title: string =
        context.resourceManager.getStringSync($r('app.string.notify_test_title').id);
      const text: string =
        context.resourceManager.getStringSync($r('app.string.notify_test_text').id);
      return await this.publishNotification(context,
        stableNotificationId('notify:test'), '', title, text, '', false);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'testNotification failed: %{public}s', describeError(err));
      return false;
    }
  }

  /**
   * 发布一条通知的底层实现：内容、wantAgent（点击打开文章）、可选动作按钮。
   * 返回是否发布成功；带 groupName 发布失败时降级为不支持分组（由调用方补聚合）。
   */
  private async publishNotification(context: common.Context, id: number, groupName: string,
    title: string, text: string, articleId: string, actions: boolean): Promise<boolean> {
    try {
      const normal: notificationManager.NotificationBasicContent = { title: title, text: text };
      const content: notificationManager.NotificationContent = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: normal
      };
      const request: notificationManager.NotificationRequest = { id: id, content: content };
      const useGroup: boolean = this.groupSupported && groupName.length > 0;
      if (useGroup) {
        request.groupName = groupName;
      }
      const agent: WantAgent | undefined = await this.buildWantAgent(
        context, articleId, '', id);
      if (agent !== undefined) {
        request.wantAgent = agent;
      }
      if (actions) {
        const buttons: Array<notificationManager.NotificationActionButton> =
          await this.buildActionButtons(context, articleId);
        if (buttons.length > 0) {
          request.actionButtons = buttons;
        }
      }
      await notificationManager.publish(request);
      return true;
    } catch (err) {
      if (this.groupSupported && groupName.length > 0) {
        this.groupSupported = false;
        hilog.warn(DOMAIN, TAG, 'publish with group failed, degrade to per-feed aggregate: %{public}s',
          describeError(err));
      } else {
        hilog.error(DOMAIN, TAG, 'publish failed: %{public}s', describeError(err));
      }
      return false;
    }
  }

  /** 「标记已读 / 收藏」两个动作按钮；某个 wantAgent 构建失败就跳过该按钮。 */
  private async buildActionButtons(context: common.Context, articleId: string):
    Promise<Array<notificationManager.NotificationActionButton>> {
    const buttons: Array<notificationManager.NotificationActionButton> = [];
    const markRead: WantAgent | undefined = await this.buildWantAgent(context, articleId,
      DeepLinkParams.ACTION_MARK_READ,
      stableNotificationId(articleId + ':' + DeepLinkParams.ACTION_MARK_READ));
    if (markRead !== undefined) {
      const label: string =
        context.resourceManager.getStringSync($r('app.string.notify_action_mark_read').id);
      buttons.push({ title: label, wantAgent: markRead });
    }
    const star: WantAgent | undefined = await this.buildWantAgent(context, articleId,
      DeepLinkParams.ACTION_STAR,
      stableNotificationId(articleId + ':' + DeepLinkParams.ACTION_STAR));
    if (star !== undefined) {
      const label: string =
        context.resourceManager.getStringSync($r('app.string.notify_action_star').id);
      buttons.push({ title: label, wantAgent: star });
    }
    return buttons;
  }

  /**
   * 构建点击通知 / 动作按钮要用的 wantAgent：带上文章 id（与可选的 action）。
   * requestCode 按「文章 + 动作」稳定派生：不同通知的 wantAgent 互不覆盖。
   * 构建失败返回 undefined（通知降级为不可点击）。
   */
  private async buildWantAgent(context: common.Context, articleId: string,
    action: string, requestCode: number): Promise<WantAgent | undefined> {
    try {
      const parameters: Record<string, Object> = {};
      if (articleId.length > 0) {
        parameters[DeepLinkParams.ARTICLE_ID] = articleId;
      }
      if (action.length > 0) {
        parameters[DeepLinkParams.ACTION] = action;
      }
      const want: Want = {
        bundleName: context.applicationInfo.name,
        abilityName: MAIN_ABILITY,
        parameters: parameters
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: requestCode,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      return await wantAgent.getWantAgent(info);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'buildWantAgent failed: %{public}s', describeError(err));
      return undefined;
    }
  }

  /**
   * 文案里的来源部分：单源用来源名，多源用「来源名 +N」。
   * 按来源去重（同一个源的多篇只算一个），来源名取首篇的 feedTitle。
   */
  private sourceSummary(added: Article[]): string {
    const sources: string[] = [];
    for (let i = 0; i < added.length; i += 1) {
      const name: string = added[i].feedTitle;
      if (name.length > 0 && sources.indexOf(name) < 0) {
        sources.push(name);
      }
    }
    if (sources.length === 0) {
      return '';
    }
    if (sources.length === 1) {
      return sources[0];
    }
    return sources[0] + ' +' + (sources.length - 1).toString();
  }
}

/** 全局唯一实例。 */
export const notifyService: NotifyService = new NotifyService();
