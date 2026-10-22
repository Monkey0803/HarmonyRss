/*
 * RetentionService.ets — 保留策略的执行编排（估算 / 清理 / 恢复 / 过期清理）。
 *
 * 原则：
 *   1. 默认「永久保留」：不删除任何文章；
 *   2. 清理永不触碰 收藏 / 稍后读 / 有高亮 / 当前打开 的文章；
 *   3. 清理先进回收站（7 天可恢复），不是直接 DELETE；
 *   4. 自动清理 6 小时节流，且全程异步，不阻塞抓取提交与界面刷新。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FeedSource } from '../model/Feed';
import { RetentionCandidate } from '../model/Search';
import { articleStore } from './ArticleStore';
import { appSettings } from '../model/AppSettings';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';
import { RetentionConstants } from '../common/constants/RssConstants';
import { RetentionDaysValue, RetentionMode } from '../common/constants/SettingsConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'RetentionService';

export class RetentionService {
  /** 当前订阅源（由 FeedViewModel 同步，用于解析源级保留天数）。 */
  private feeds: FeedSource[] = [];
  /** 偏好库上下文（读写 6 小时节流时间戳）。 */
  private context: common.Context | undefined = undefined;
  /** 当前打开的文章 id：清理时永不删除。 */
  private protectedArticleId: string = '';

  /** 由 FeedViewModel 在装配 / 订阅变更时调用。 */
  configure(context: common.Context, feeds: FeedSource[]): void {
    this.context = context;
    this.feeds = feeds;
  }

  /** 订阅源列表变化时同步（不重复传 context）。 */
  setFeeds(feeds: FeedSource[]): void {
    this.feeds = feeds;
  }

  /** 当前打开的文章变化时同步（保护它不被清理）。 */
  setProtectedArticle(articleId: string): void {
    this.protectedArticleId = articleId;
  }

  /**
   * 某个源生效的保留天数：源级覆盖优先；0 表示永久保留。
   * 全局为「仅保留未读与收藏」时天数无意义，返回 0。
   */
  effectiveRetentionDays(feed: FeedSource | undefined): number {
    if (feed !== undefined && feed.retentionDays !== 0) {
      // -1 表示该源永久保留（<= 0 即不清理）。
      return feed.retentionDays;
    }
    if (appSettings.retentionMode !== RetentionMode.DAYS) {
      return 0;
    }
    return RetentionDaysValue.of(appSettings.retentionDays);
  }

  /** 源级覆盖表：只有 > 0 的源才进入（0 = 跟随全局）。 */
  private feedDays(): Map<string, number> {
    const map: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < this.feeds.length; i += 1) {
      const feed: FeedSource = this.feeds[i];
      if (feed.retentionDays !== 0) {
        map.set(feed.id, feed.retentionDays);
      }
    }
    return map;
  }

  /** 当前策略下的清理候选。 */
  private async candidates(): Promise<RetentionCandidate[]> {
    const protectedIds: string[] = [];
    if (this.protectedArticleId.length > 0) {
      protectedIds.push(this.protectedArticleId);
    }
    return await articleStore.retentionCandidates(appSettings.retentionMode,
      RetentionDaysValue.of(appSettings.retentionDays), this.feedDays(), protectedIds);
  }

  /** 可清理条数（存储页展示 / 清理前预览）。 */
  async estimate(): Promise<number> {
    const candidates: RetentionCandidate[] = await this.candidates();
    return candidates.length;
  }

  /** 立即清理（用户手动触发 / 后台任务结束）。返回实际移入回收站的条数。 */
  async runNow(): Promise<number> {
    const candidates: RetentionCandidate[] = await this.candidates();
    if (candidates.length === 0) {
      await this.markRun();
      return 0;
    }
    const ids: string[] = [];
    for (let i = 0; i < candidates.length; i += 1) {
      ids.push(candidates[i].id);
    }
    const moved: number = await articleStore.archiveToTrash(ids);
    await this.markRun();
    hilog.info(DOMAIN, TAG, 'retention cleaned %{public}d articles', moved);
    return moved;
  }

  /** 按 6 小时节流执行自动清理；顺带清掉过期回收站条目。 */
  async runIfDue(): Promise<number> {
    await this.purgeExpired();
    const due: boolean = await this.isDue();
    if (!due) {
      return 0;
    }
    return await this.runNow();
  }

  /** 恢复回收站全部文章（7 天内的撤销入口）。 */
  async restoreAll(): Promise<number> {
    const ids: string[] = await articleStore.trashIds();
    if (ids.length === 0) {
      return 0;
    }
    return await articleStore.restoreTrash(ids);
  }

  /** 清理超过 7 天的回收站条目。 */
  async purgeExpired(): Promise<number> {
    return await articleStore.purgeTrash(Date.now() - RetentionConstants.TRASH_TTL_MS);
  }

  /** 距离上次自动清理是否已超过节流间隔。 */
  private async isDue(): Promise<boolean> {
    const context: common.Context | undefined = this.context;
    if (context === undefined) {
      return true;
    }
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      const last: number = store.getSync(PreferencesConstants.KEY_LAST_RETENTION_RUN, 0) as number;
      if (!Number.isFinite(last) || last <= 0) {
        return true;
      }
      return Date.now() - last >= RetentionConstants.MIN_INTERVAL_MS;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'read last run failed: %{public}d', error.code);
      return true;
    }
  }

  private async markRun(): Promise<void> {
    const context: common.Context | undefined = this.context;
    if (context === undefined) {
      return;
    }
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      store.putSync(PreferencesConstants.KEY_LAST_RETENTION_RUN, Date.now());
      await store.flush();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'write last run failed: %{public}d', error.code);
    }
  }
}

/** 全局唯一实例。 */
export const retentionService: RetentionService = new RetentionService();
