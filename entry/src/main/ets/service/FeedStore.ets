/*
 * FeedStore.ets — 订阅源列表的落盘与恢复（@ohos.data.preferences）。
 *
 * 只存订阅地址与语义设置（JSON 数组），读出来逐条做类型校验与归一：
 *   - 旧记录缺新字段 → 用默认值（不丢源、不误停用）；
 *   - 脏值（未知枚举 / 负数 / 超大天数）→ 回退到默认 / 跟随全局。
 * 首次运行（读不到值 / 全部非法）时播种内置订阅源。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';
import { FeedSource } from '../model/Feed';
import { BackupFeed } from '../model/Backup';
import { UrlText } from '../common/utils/UrlText';
import { DedupeKeys } from './DedupeKeys';
import { DEFAULT_FEEDS, FeedSeed } from '../model/DefaultFeeds';
import { FullTextMode, TriState } from '../common/constants/SettingsConstants';

/** 落盘用的扁平结构（新字段可选：旧记录读不到时按默认值处理）。 */
interface FeedRecord {
  title: string;
  url: string;
  siteUrl: string;
  group: string;
  etag: string;
  lastModified: string;
  lastUpdated?: number;
  lastError?: string;
  enabled?: boolean;
  fetchIntervalMinutes?: number;
  fullTextMode?: string;
  retentionDays?: number;
  notify?: string;
  markReadOnScroll?: string;
  failureCount?: number;
}

/** 抓取间隔允许的取值（0 = 跟随全局）。 */
const INTERVAL_VALUES: number[] = [0, 15, 30, 60, 180];
/** 源级保留天数允许的取值（0 = 跟随全局；-1 = 该源永久保留）。 */
const RETENTION_VALUES: number[] = [-1, 0, 30, 90, 365];

/** 抓取间隔归一（导出供 FeedViewModel 复用）。 */
export function normalizeFeedInterval(value: number): number {
  for (let i = 0; i < INTERVAL_VALUES.length; i += 1) {
    if (INTERVAL_VALUES[i] === value) {
      return value;
    }
  }
  return 0;
}

/** 源级保留天数归一。 */
export function normalizeFeedRetention(value: number): number {
  for (let i = 0; i < RETENTION_VALUES.length; i += 1) {
    if (RETENTION_VALUES[i] === value) {
      return value;
    }
  }
  return 0;
}

/** 全文策略归一。 */
export function normalizeFeedFullTextMode(value: string): string {
  if (value === FullTextMode.AUTO || value === FullTextMode.ALWAYS || value === FullTextMode.NEVER) {
    return value;
  }
  return FullTextMode.GLOBAL;
}

/** 三态归一。 */
export function normalizeFeedTriState(value: string): string {
  if (value === TriState.ON || value === TriState.OFF) {
    return value;
  }
  return TriState.GLOBAL;
}

/** 把落盘 JSON 解成订阅源（纯函数，便于单测旧记录兼容与脏值归一）。 */
export function decodeFeedRecords(text: string): FeedSource[] {
  const feeds: FeedSource[] = [];
  if (text.length === 0) {
    return feeds;
  }
  try {
    const records: FeedRecord[] = JSON.parse(text) as FeedRecord[];
    for (let i = 0; i < records.length; i += 1) {
      const record: FeedRecord = records[i];
      const url: string = typeof record.url === 'string' ? record.url.trim() : '';
      if (url.length === 0) {
        continue;
      }
      const title: string = typeof record.title === 'string' && record.title.length > 0
        ? record.title
        : url;
      const siteUrl: string = typeof record.siteUrl === 'string' ? record.siteUrl : '';
      const group: string = typeof record.group === 'string' ? record.group : '';
      const feed: FeedSource = new FeedSource(url, title, url, siteUrl, group);
      // 老数据没有这些字段，读不到就当作「没有校验值 / 从未同步」。
      feed.etag = typeof record.etag === 'string' ? record.etag : '';
      feed.lastModified = typeof record.lastModified === 'string' ? record.lastModified : '';
      feed.lastUpdated = typeof record.lastUpdated === 'number' && record.lastUpdated > 0
        ? record.lastUpdated : 0;
      feed.lastError = typeof record.lastError === 'string' ? record.lastError : '';
      // 新字段：旧记录一律回退默认（启用以避免升级后「所有源都被停用」）。
      feed.enabled = typeof record.enabled === 'boolean' ? record.enabled : true;
      feed.fetchIntervalMinutes = typeof record.fetchIntervalMinutes === 'number'
        ? normalizeFeedInterval(record.fetchIntervalMinutes) : 0;
      feed.fullTextMode = typeof record.fullTextMode === 'string'
        ? normalizeFeedFullTextMode(record.fullTextMode) : FullTextMode.GLOBAL;
      feed.retentionDays = typeof record.retentionDays === 'number'
        ? normalizeFeedRetention(record.retentionDays) : 0;
      feed.notify = typeof record.notify === 'string' ? normalizeFeedTriState(record.notify) : TriState.GLOBAL;
      feed.markReadOnScroll = typeof record.markReadOnScroll === 'string'
        ? normalizeFeedTriState(record.markReadOnScroll) : TriState.GLOBAL;
      feed.failureCount = typeof record.failureCount === 'number' && record.failureCount > 0
        ? Math.round(record.failureCount) : 0;
      feeds.push(feed);
    }
  } catch (err) {
    // JSON.parse 抛的是 SyntaxError，没有 BusinessError.code；直接拼 code 会在 catch 里二次崩溃。
    const error: BusinessError = err as BusinessError;
    const detail: string = error.message !== undefined ? error.message : 'invalid json';
    console.error('FeedStore.decode failed: ' + detail);
  }
  return feeds;
}

/** 把订阅源编成落盘 JSON（纯函数）。 */
export function encodeFeeds(feeds: FeedSource[]): string {
  const records: FeedRecord[] = [];
  for (let i = 0; i < feeds.length; i += 1) {
    const feed: FeedSource = feeds[i];
    const record: FeedRecord = {
      title: feed.title,
      url: feed.url,
      siteUrl: feed.siteUrl,
      group: feed.group,
      etag: feed.etag,
      lastModified: feed.lastModified,
      lastUpdated: feed.lastUpdated,
      lastError: feed.lastError,
      enabled: feed.enabled,
      fetchIntervalMinutes: feed.fetchIntervalMinutes,
      fullTextMode: feed.fullTextMode,
      retentionDays: feed.retentionDays,
      notify: feed.notify,
      markReadOnScroll: feed.markReadOnScroll,
      failureCount: feed.failureCount
    };
    records.push(record);
  }
  return JSON.stringify(records);
}

/**
 * 订阅合并键：优先用归一化 URL，归一化失败时退回去空白后的原串 / id。
 * 最后再套一遍跨源去重的 URL 归一（小写 scheme / host、去追踪参数、忽略末尾斜杠），
 * 避免同一订阅因大小写或尾斜杠差异被重复导入。
 * 纯函数，导出供备份合并单测复用。
 */
export function feedMergeKey(url: string, fallbackId: string): string {
  const normalized: string = UrlText.normalizeUrlInput(url);
  let base: string = normalized;
  if (base.length === 0) {
    const trimmed: string = url.trim();
    base = trimmed.length > 0 ? trimmed : fallbackId.trim();
  }
  if (base.length === 0) {
    return '';
  }
  return DedupeKeys.urlKey(base);
}

/**
 * 合并备份订阅（纯函数）：按归一化 URL 去重。
 *   - 已存在：保留本地（不覆盖标题 / 分组 / 抓取信息等）；
 *   - 不存在：用备份数据新建 FeedSource，并应用新字段；
 *   - 备份内部的重复项也只保留第一条。
 * 返回新数组，不修改入参。
 */
export function mergeFeedsForBackup(local: FeedSource[], incoming: BackupFeed[]): FeedSource[] {
  const merged: FeedSource[] = local.slice();
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < merged.length; i += 1) {
    const key: string = feedMergeKey(merged[i].url, merged[i].id);
    if (key.length > 0) {
      seen.add(key);
    }
  }
  for (let i = 0; i < incoming.length; i += 1) {
    const item: BackupFeed = incoming[i];
    // 合并键严格用归一化地址：归一化失败（非法地址）直接跳过，避免写入脏订阅。
    const url: string = UrlText.normalizeUrlInput(item.url);
    if (url.length === 0) {
      continue;
    }
    const key: string = feedMergeKey(url, '');
    if (key.length === 0 || seen.has(key)) {
      continue;
    }
    seen.add(key);
    const title: string = item.title.length > 0 ? item.title : url;
    const feed: FeedSource = new FeedSource(url, title, url, item.siteUrl, item.group);
    feed.enabled = item.enabled;
    feed.fetchIntervalMinutes = normalizeFeedInterval(item.fetchIntervalMinutes);
    feed.fullTextMode = normalizeFeedFullTextMode(item.fullTextMode);
    feed.retentionDays = normalizeFeedRetention(item.retentionDays);
    feed.notify = normalizeFeedTriState(item.notify);
    feed.markReadOnScroll = normalizeFeedTriState(item.markReadOnScroll);
    merged.push(feed);
  }
  return merged;
}

export class FeedStore {
  private store: preferences.Preferences | undefined = undefined;

  /**
   * 打开偏好库并读出订阅源。
   * seedWhenEmpty = true（默认）：没有有效数据时返回内置种子（首启体验）；
   * false：如实返回空数组（后台任务用，避免用户删光订阅后又被种子写回文章）。
   */
  async load(context: common.Context, seedWhenEmpty: boolean = true): Promise<FeedSource[]> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      this.store = store;
      const raw: preferences.ValueType =
        store.getSync(PreferencesConstants.KEY_RSS_FEEDS, '');
      const text: string = typeof raw === 'string' ? raw : '';
      const stored: FeedSource[] = decodeFeedRecords(text);
      if (stored.length > 0) {
        return stored;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('FeedStore.load failed: ' + error.code.toString());
    }
    const seeds: FeedSource[] = [];
    if (!seedWhenEmpty) {
      return seeds;
    }
    for (let i = 0; i < DEFAULT_FEEDS.length; i += 1) {
      const seed: FeedSeed = DEFAULT_FEEDS[i];
      seeds.push(new FeedSource(seed.url, seed.title, seed.url, ''));
    }
    return seeds;
  }

  /** 全量写回订阅源。 */
  save(feeds: FeedSource[]): void {
    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return;
    }
    // putSync 标注了可能抛异常，要求调用点 catch：写失败只影响下次启动的恢复。
    try {
      store.putSync(PreferencesConstants.KEY_RSS_FEEDS, encodeFeeds(feeds));
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('FeedStore.putSync failed: ' + error.code.toString());
      return;
    }
    store.flush().catch((err: BusinessError) => {
      console.error('FeedStore.flush failed: ' + err.code.toString());
    });
  }
}

export const feedStore: FeedStore = new FeedStore();
