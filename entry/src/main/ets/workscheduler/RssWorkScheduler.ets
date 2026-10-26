/*
 * RssWorkScheduler.ets — 后台定时抓取的执行入口（WorkSchedulerExtensionAbility）。
 *
 * 系统在满足条件（网络可用等）时唤醒本扩展，这里做一次「读订阅源 → 抓取 → 写本地库 → 保留清理」，
 * 完成后主动 stopWork 结束本次任务。
 *
 * 抓取门控与前台一致：
 *   - 源停用（enabled=false）不抓、不通知，但历史文章保留；
 *   - 源级抓取间隔（fetchIntervalMinutes>0）优先于全局自动刷新间隔；
 *   - 通知走 NotifyService.notifyNew（与前台共用同一套策略：源开关 / 关键词 / 免打扰 / 摘要）。
 *
 * 注意：这里**不依赖 FeedViewModel**（扩展与界面的生命周期无关），只复用 service 层。
 */

import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article, FeedSource } from '../model/Feed';
import { feedStore } from '../service/FeedStore';
import { feedService, FeedFetchResult } from '../service/FeedService';
import { articleStore } from '../service/ArticleStore';
import { toArticles } from '../service/ArticleMapper';
import { settingsStore } from '../service/SettingsStore';
import { appSettings } from '../model/AppSettings';
import { notifyService } from '../service/NotifyService';
import { retentionService } from '../service/RetentionService';
import { ruleService } from '../service/RuleService';
import { AutoRefreshMinutes } from '../common/constants/SettingsConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'RssWorkScheduler';
const MINUTE_MS: number = 60 * 1000;

export default class RssWorkScheduler extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    this.fetchAll()
      .then(() => {
        workScheduler.stopWork(work, true);
      })
      .catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'work failed: %{public}s', err.message);
        workScheduler.stopWork(work, true);
      });
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    hilog.info(DOMAIN, TAG, 'onWorkStop: %{public}d', work.workId);
  }

  /** 该源当前是否到抓取时间（停用 / 未配置间隔时返回 false）。 */
  private isDue(feed: FeedSource): boolean {
    if (!feed.enabled) {
      return false;
    }
    const minutes: number = feed.fetchIntervalMinutes > 0
      ? feed.fetchIntervalMinutes
      : AutoRefreshMinutes.of(appSettings.autoRefresh);
    if (minutes <= 0) {
      return false;
    }
    return feed.lastUpdated <= 0 || Date.now() - feed.lastUpdated >= minutes * MINUTE_MS;
  }

  private async fetchAll(): Promise<void> {
    const context: common.Context = this.context as common.Context;
    // 不播种内置源：用户删光订阅后，后台任务不应该再把默认源的文章写回来。
    const feeds: FeedSource[] = await feedStore.load(context, false);
    if (feeds.length === 0) {
      return;
    }
    await articleStore.open(context);
    // 通知 / 抓取间隔 / 保留策略都存在偏好库里：扩展与界面可能不是同一份模块状态，这里自己读一次。
    await settingsStore.load(context);
    const fresh: Article[] = [];
    for (let i = 0; i < feeds.length; i += 1) {
      const feed: FeedSource = feeds[i];
      if (!this.isDue(feed)) {
        continue;
      }
      try {
        const result: FeedFetchResult =
          await feedService.fetchFeed(feed.url, feed.etag, feed.lastModified);
        // 把新的校验值写回订阅源，下一次（界面或后台）就能命中 304。
        feed.etag = result.etag;
        feed.lastModified = result.lastModified;
        if (result.parsed !== undefined) {
          toArticles(feed, result.parsed, fresh);
        }
        feed.lastError = '';
        feed.failureCount = 0;
        feed.lastUpdated = Date.now();
      } catch (err) {
        const error: Error = err as Error;
        hilog.warn(DOMAIN, TAG, 'fetch failed: %{public}s', error.message);
        feed.failureCount = feed.failureCount + 1;
        feed.lastError = error.message;
      }
    }
    // 只有真正新插入的文章才执行规则（重复抓取到的历史文章不回溯）。
    const inserted: Article[] = articleStore.insertNew(fresh);
    if (inserted.length > 0) {
      // 后台抓取同样要跑本地规则；失败只记日志，不影响入库与通知。
      await ruleService.applyToNew(inserted);
    }
    // 校验值 / 健康状态变了要落盘，否则下次条件请求拿不到。
    feedStore.save(feeds);
    hilog.info(DOMAIN, TAG, 'background refresh done, fetched: %{public}d', fresh.length);

    // 通知：与前台共用 notifyNew（策略过滤 / 免打扰入队 / 分组限流都在里面）。
    // 只传真正新入库的文章，避免重复抓取的历史文章触发重复通知。
    if (inserted.length > 0) {
      await notifyService.notifyNew(context, feeds, inserted);
    }

    // 抓取后执行保留清理与回收站过期清理（低优先级，异常不影响本次抓取结果）。
    try {
      retentionService.configure(context, feeds);
      retentionService.setFeeds(feeds);
      await retentionService.purgeExpired();
      await retentionService.runNow();
    } catch (err) {
      const error: Error = err as Error;
      hilog.warn(DOMAIN, TAG, 'retention failed: %{public}s', error.message);
    }

    // 离开免打扰后补发队列；每日摘要到点且今天没发过则发一条。
    await notifyService.flushQueueIfDue(context);
    await notifyService.maybeSendDigest(context);
  }
}
