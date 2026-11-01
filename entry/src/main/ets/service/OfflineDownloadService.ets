/* 用户选定范围的离线正文准备；任务从数据库重建，应用重启后可继续。 */
import { FeedSource, Article } from '../model/Feed';
import { appSettings } from '../model/AppSettings';
import { FullTextMode } from '../common/constants/SettingsConstants';
import { articleStore } from './ArticleStore';
import { articleContentService } from './ArticleContentService';
import { NetworkStatus } from './NetworkStatus';
import { settingsStore } from './SettingsStore';

const MAX_BYTES: number = 200 * 1024 * 1024;

export function selectedForOffline(feed: FeedSource, feedIds: string[], groups: string[]): boolean {
  return feedIds.indexOf(feed.id) >= 0 || (feed.group.length > 0 && groups.indexOf(feed.group) >= 0);
}

@ObservedV2
export class OfflineDownloadService {
  @Trace running: boolean = false;
  @Trace completed: number = 0;
  @Trace total: number = 0;
  @Trace failed: number = 0;
  @Trace atLimit: boolean = false;
  @Trace bytes: number = 0;
  private publishState: (id: string, state: string) => void = () => {};

  bindStatePublisher(callback: (id: string, state: string) => void): void {
    this.publishState = callback;
  }

  isSelected(feed: FeedSource): boolean {
    return selectedForOffline(feed, appSettings.offlineFeedIds, appSettings.offlineGroups);
  }

  toggleFeed(feedId: string, enabled: boolean): void {
    appSettings.offlineFeedIds = enabled
      ? appSettings.offlineFeedIds.concat([feedId]).filter((id: string, index: number, all: string[]) =>
        all.indexOf(id) === index)
      : appSettings.offlineFeedIds.filter((id: string) => id !== feedId);
    settingsStore.save();
  }

  toggleGroup(group: string, enabled: boolean): void {
    if (group.length === 0) {
      return;
    }
    appSettings.offlineGroups = enabled
      ? appSettings.offlineGroups.concat([group]).filter((id: string, index: number, all: string[]) =>
        all.indexOf(id) === index)
      : appSettings.offlineGroups.filter((id: string) => id !== group);
    settingsStore.save();
  }

  /** 用户指定单篇下载；已读、稍后读网页和未选中的源均可使用。 */
  async prepareArticle(id: string, fullTextMode: string, retry: boolean = false): Promise<string> {
    await articleStore.whenReady();
    const previous: string = await articleStore.offlineState(id);
    if (previous === 'full' && !retry) {
      return previous;
    }
    if (!NetworkStatus.isOnline()) {
      return previous;
    }
    this.bytes = await articleStore.offlineCacheBytes();
    if (this.bytes >= MAX_BYTES) {
      this.atLimit = true;
      return previous;
    }
    const article: Article | undefined = await articleStore.loadById(id);
    if (article === undefined) {
      return 'none';
    }
    const oldHtml: string = article.readerHtml;
    const oldText: string = article.plainText;
    if (retry && oldHtml.length > 0) {
      article.readerHtml = '';
      await articleStore.clearOfflineArticle(id);
    }
    try {
      await articleContentService.ensureReaderHtml(article, fullTextMode);
      const state: string = await articleStore.offlineState(id);
      if (state !== 'none') {
        this.publishState(id, state);
        this.bytes = await articleStore.offlineCacheBytes();
        return state;
      }
    } catch (err) {
    }
    if (retry && oldHtml.length > 0) {
      articleStore.setReaderHtml(id, oldHtml, oldText);
      this.publishState(id, previous);
    }
    return previous;
  }

  async clearArticle(id: string): Promise<boolean> {
    const cleared: boolean = await articleStore.clearOfflineArticle(id);
    if (cleared) {
      this.publishState(id, 'none');
      this.bytes = await articleStore.offlineCacheBytes();
    }
    return cleared;
  }

  /** 手动调用绕过 Wi-Fi 开关；总开关关闭时仍须有用户选择的范围。 */
  async prepare(feeds: FeedSource[], manual: boolean = false): Promise<void> {
    if (this.running || (!manual && !appSettings.offlineEnabled) || !NetworkStatus.isOnline() ||
      (!manual && appSettings.offlineWifiOnly && !NetworkStatus.isUnmetered())) {
      return;
    }
    this.running = true;
    this.completed = 0;
    this.total = 0;
    this.failed = 0;
    this.atLimit = false;
    try {
      await articleStore.whenReady();
      const selected: FeedSource[] = feeds.filter((feed: FeedSource) =>
        (manual || feed.enabled) && this.isSelected(feed));
      const queue: Article[] = [];
      const modes: Map<string, string> = new Map<string, string>();
      for (let i = 0; i < selected.length; i += 1) {
        const feed: FeedSource = selected[i];
        modes.set(feed.id, feed.fullTextMode === FullTextMode.GLOBAL ? FullTextMode.AUTO : feed.fullTextMode);
        const candidates: Article[] = await articleStore.offlineCandidates(feed.id, 20);
        for (let j = 0; j < candidates.length; j += 1) {
          const state: string = await articleStore.offlineState(candidates[j].id);
          if (state === 'none' || state === 'text') {
            queue.push(candidates[j]);
          }
        }
      }
      this.total = queue.length;
      for (let i = 0; i < queue.length; i += 1) {
        if (!NetworkStatus.isOnline() || (!manual && appSettings.offlineWifiOnly && !NetworkStatus.isUnmetered()) ||
          (!manual && !appSettings.offlineEnabled)) {
          break;
        }
        this.bytes = await articleStore.offlineCacheBytes();
        if (this.bytes >= MAX_BYTES) {
          this.atLimit = true;
          break;
        }
        const article: Article | undefined = await articleStore.loadById(queue[i].id);
        if (article === undefined) {
          this.failed++;
          continue;
        }
        try {
          await articleContentService.ensureReaderHtml(article, modes.get(article.feedId) || FullTextMode.AUTO);
          const state: string = await articleStore.offlineState(article.id);
          if (state === 'none') {
            this.failed++;
          } else {
            this.completed++;
            this.publishState(article.id, state);
          }
        } catch (err) {
          this.failed++;
        }
      }
      this.bytes = await articleStore.offlineCacheBytes();
    } finally {
      this.running = false;
    }
  }
}

export const offlineDownloadService: OfflineDownloadService = new OfflineDownloadService();
