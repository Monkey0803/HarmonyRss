/*
 * RssWorkScheduler.ets — 后台定时抓取的执行入口（WorkSchedulerExtensionAbility）。
 *
 * 系统在满足条件（网络可用等）时唤醒本扩展，这里做一次「读订阅源 → 抓取 → 写本地库」，
 * 完成后主动 stopWork 结束本次任务。
 *
 * 注意：这里**不依赖 FeedViewModel**（扩展与界面的生命周期无关），只复用 service 层：
 * FeedStore（订阅源）/ FeedService（抓取）/ ArticleStore（缓存）/ ArticleMapper（转换）。
 * 单个订阅源失败不影响其他源；已读与收藏由本地库保留，入库是 INSERT OR IGNORE。
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

const DOMAIN: number = 0x0000;
const TAG: string = 'RssWorkScheduler';

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

  private async fetchAll(): Promise<void> {
    const context: common.Context = this.context as common.Context;
    // 不播种内置源：用户删光订阅后，后台任务不应该再把默认源的文章写回来。
    const feeds: FeedSource[] = await feedStore.load(context, false);
    if (feeds.length === 0) {
      return;
    }
    await articleStore.open(context);
    // 通知开关存在偏好库里：扩展与界面的运行上下文可能不是同一份模块状态，所以这里自己读一次。
    await settingsStore.load(context);
    const before: number = await articleStore.countAll();
    const fresh: Article[] = [];
    for (let i = 0; i < feeds.length; i += 1) {
      const feed: FeedSource = feeds[i];
      try {
        const result: FeedFetchResult =
          await feedService.fetchFeed(feed.url, feed.etag, feed.lastModified);
        // 把新的校验值写回订阅源，下一次（界面或后台）就能命中 304。
        feed.etag = result.etag;
        feed.lastModified = result.lastModified;
        if (result.parsed !== undefined) {
          toArticles(feed, result.parsed, fresh);
        }
      } catch (err) {
        const error: Error = err as Error;
        hilog.warn(DOMAIN, TAG, 'fetch failed: %{public}s', error.message);
      }
    }
    articleStore.insertNew(fresh);
    articleStore.prune();
    // 校验值变了要落盘，否则下次条件请求拿不到（扩展与界面共用同一份偏好库）。
    feedStore.save(feeds);
    hilog.info(DOMAIN, TAG, 'background refresh done, fetched: %{public}d', fresh.length);

    if (appSettings.notifyNewArticles) {
      const after: number = await articleStore.countAll();
      const added: number = after - before;
      if (added > 0) {
        await notifyService.publishNewArticles(context, added, this.firstTitle(fresh));
      }
    }
  }

  /** 通知正文里给一个标题示例（优先未读的最新一条，这里直接取抓取到的第一条）。 */
  private firstTitle(fresh: Article[]): string {
    return fresh.length > 0 ? fresh[0].title : '';
  }
}
