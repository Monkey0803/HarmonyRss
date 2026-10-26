/*
 * NotifyStore.ets — 通知策略 / 待通知队列 / 摘要日期的偏好库读写。
 *
 * 与 SettingsStore 共用同一个偏好库（PreferencesConstants.STORE_NAME）：
 *   - 策略（免打扰 / 摘要 / 关键词）与 AppSettings 字段双向同步，界面读哪边都一致；
 *   - 队列与「最近摘要日期」只在这里读写。
 * 读一律先归一：脏值 / 损坏 JSON 一律退回默认，绝不让坏数据阻断抓取与通知。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';
import { CommonConstants } from '../common/constants/CommonConstants';
import { NotifyPolicy, NotifyQueueItem } from '../model/Notify';
import { appSettings } from '../model/AppSettings';
import { clampDigestHour, clampMinuteOfDay, decodeKeywords, encodeKeywords, normalizePolicy } from './NotifyPolicy';

const DOMAIN: number = 0x0000;
const TAG: string = 'NotifyStore';

/** 队列落盘的扁平结构。 */
interface QueueRecord {
  articleId: string;
  feedId: string;
  at: number;
}

/** 该文章在队列里的下标；不存在返回 -1。 */
function indexOfArticle(items: NotifyQueueItem[], articleId: string): number {
  for (let i = 0; i < items.length; i += 1) {
    if (items[i].articleId === articleId) {
      return i;
    }
  }
  return -1;
}

/**
 * 队列归一：按 articleId 去重（后来的替换先前的，视为更新），按入队顺序排列，
 * 超过上限时丢弃最旧的（保留最新 NOTIFY_QUEUE_MAX 条）。
 */
export function normalizeQueue(items: NotifyQueueItem[]): NotifyQueueItem[] {
  const result: NotifyQueueItem[] = [];
  for (let i = 0; i < items.length; i += 1) {
    const item: NotifyQueueItem = items[i];
    if (item.articleId.length === 0) {
      continue;
    }
    const index: number = indexOfArticle(result, item.articleId);
    if (index >= 0) {
      result.splice(index, 1);
    }
    const at: number = Number.isFinite(item.at) && item.at > 0 ? item.at : 0;
    result.push(new NotifyQueueItem(item.articleId, item.feedId, at));
  }
  const overflow: number = result.length - CommonConstants.NOTIFY_QUEUE_MAX;
  if (overflow > 0) {
    result.splice(0, overflow);
  }
  return result;
}

/** 解码队列 JSON（非法项丢弃；失败返回空数组）。 */
export function decodeQueue(text: string): NotifyQueueItem[] {
  if (text.length === 0) {
    return [];
  }
  try {
    const records: QueueRecord[] = JSON.parse(text) as QueueRecord[];
    const items: NotifyQueueItem[] = [];
    for (let i = 0; i < records.length; i += 1) {
      const record: QueueRecord = records[i];
      const articleId: string = typeof record.articleId === 'string' ? record.articleId : '';
      if (articleId.length === 0) {
        continue;
      }
      const feedId: string = typeof record.feedId === 'string' ? record.feedId : '';
      const at: number = typeof record.at === 'number' ? record.at : 0;
      items.push(new NotifyQueueItem(articleId, feedId, at));
    }
    return normalizeQueue(items);
  } catch (err) {
    const error: BusinessError = err as BusinessError;
    const detail: string = error.message !== undefined ? error.message : 'invalid json';
    hilog.warn(DOMAIN, TAG, 'decodeQueue failed: %{public}s', detail);
    return [];
  }
}

/** 编码队列 JSON（写前归一，落盘即已去重且不超限）。 */
export function encodeQueue(items: NotifyQueueItem[]): string {
  const normalized: NotifyQueueItem[] = normalizeQueue(items);
  const records: QueueRecord[] = [];
  for (let i = 0; i < normalized.length; i += 1) {
    const item: NotifyQueueItem = normalized[i];
    const record: QueueRecord = { articleId: item.articleId, feedId: item.feedId, at: item.at };
    records.push(record);
  }
  return JSON.stringify(records);
}

export class NotifyStore {
  private store: preferences.Preferences | undefined = undefined;

  /** 打开偏好库（宿主启动或通知服务首次使用前调用）。失败时通知逻辑退回默认值，不抛错。 */
  async open(context: common.Context): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'open preferences failed: %{public}d', error.code);
    }
  }

  /**
   * 读策略：偏好库优先；缺 key / 未 open 时回退 appSettings（即默认值）。
   * 结果一律归一（时间夹到 0–1439 / 0–23、关键词去重截断）。
   */
  loadPolicy(): NotifyPolicy {
    const dndEnabled: boolean = appSettings.notifyDndEnabled;
    const dndStart: number = appSettings.notifyDndStart;
    const dndEnd: number = appSettings.notifyDndEnd;
    const digestEnabled: boolean = appSettings.notifyDigestEnabled;
    const digestHour: number = appSettings.notifyDigestHour;
    const keywords: string[] = appSettings.notifyKeywords;

    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return normalizePolicy(new NotifyPolicy(dndEnabled, dndStart, dndEnd, digestEnabled, digestHour, keywords));
    }
    try {
      const rawDndEnabled: preferences.ValueType =
        store.getSync(PreferencesConstants.KEY_NOTIFY_DND_ENABLED, dndEnabled);
      const rawDndStart: preferences.ValueType =
        store.getSync(PreferencesConstants.KEY_NOTIFY_DND_START, dndStart);
      const rawDndEnd: preferences.ValueType =
        store.getSync(PreferencesConstants.KEY_NOTIFY_DND_END, dndEnd);
      const rawDigestEnabled: preferences.ValueType =
        store.getSync(PreferencesConstants.KEY_NOTIFY_DIGEST_ENABLED, digestEnabled);
      const rawDigestHour: preferences.ValueType =
        store.getSync(PreferencesConstants.KEY_NOTIFY_DIGEST_HOUR, digestHour);
      const rawKeywords: preferences.ValueType =
        store.getSync(PreferencesConstants.KEY_NOTIFY_KEYWORDS, '');

      const storedKeywords: string = typeof rawKeywords === 'string' ? rawKeywords : '';
      const policy: NotifyPolicy = new NotifyPolicy(
        typeof rawDndEnabled === 'boolean' ? rawDndEnabled : dndEnabled,
        typeof rawDndStart === 'number' ? rawDndStart : dndStart,
        typeof rawDndEnd === 'number' ? rawDndEnd : dndEnd,
        typeof rawDigestEnabled === 'boolean' ? rawDigestEnabled : digestEnabled,
        typeof rawDigestHour === 'number' ? rawDigestHour : digestHour,
        storedKeywords.length > 0 ? decodeKeywords(storedKeywords) : keywords);
      return normalizePolicy(policy);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'loadPolicy failed: %{public}d', error.code);
      return normalizePolicy(new NotifyPolicy(dndEnabled, dndStart, dndEnd, digestEnabled, digestHour, keywords));
    }
  }

  /** 保存策略：归一后同时写偏好库与 appSettings（界面与后台任务读到的值保持一致）。 */
  savePolicy(policy: NotifyPolicy): void {
    const normalized: NotifyPolicy = normalizePolicy(policy);
    appSettings.notifyDndEnabled = normalized.dndEnabled;
    appSettings.notifyDndStart = clampMinuteOfDay(normalized.dndStart, appSettings.notifyDndStart);
    appSettings.notifyDndEnd = clampMinuteOfDay(normalized.dndEnd, appSettings.notifyDndEnd);
    appSettings.notifyDigestEnabled = normalized.digestEnabled;
    appSettings.notifyDigestHour = clampDigestHour(normalized.digestHour, appSettings.notifyDigestHour);
    appSettings.notifyKeywords = normalized.keywords.slice();

    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(PreferencesConstants.KEY_NOTIFY_DND_ENABLED, normalized.dndEnabled);
      store.putSync(PreferencesConstants.KEY_NOTIFY_DND_START, appSettings.notifyDndStart);
      store.putSync(PreferencesConstants.KEY_NOTIFY_DND_END, appSettings.notifyDndEnd);
      store.putSync(PreferencesConstants.KEY_NOTIFY_DIGEST_ENABLED, normalized.digestEnabled);
      store.putSync(PreferencesConstants.KEY_NOTIFY_DIGEST_HOUR, appSettings.notifyDigestHour);
      store.putSync(PreferencesConstants.KEY_NOTIFY_KEYWORDS, encodeKeywords(normalized.keywords));
      store.flush().catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'flush policy failed: %{public}d', err.code);
      });
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'savePolicy failed: %{public}d', error.code);
    }
  }

  /** 读待通知队列（已去重、已限长；未 open / 损坏时为空数组）。 */
  loadQueue(): NotifyQueueItem[] {
    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return [];
    }
    try {
      const raw: preferences.ValueType = store.getSync(PreferencesConstants.KEY_NOTIFY_QUEUE, '');
      return decodeQueue(typeof raw === 'string' ? raw : '');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'loadQueue failed: %{public}d', error.code);
      return [];
    }
  }

  /** 保存待通知队列（写前去重 + 限长）。 */
  saveQueue(items: NotifyQueueItem[]): void {
    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(PreferencesConstants.KEY_NOTIFY_QUEUE, encodeQueue(items));
      store.flush().catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'flush queue failed: %{public}d', err.code);
      });
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'saveQueue failed: %{public}d', error.code);
    }
  }

  /** 最近一次发送每日摘要的本地日期（YYYY-MM-DD）；没发过返回空串。 */
  lastDigestDate(): string {
    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return '';
    }
    try {
      const raw: preferences.ValueType = store.getSync(PreferencesConstants.KEY_NOTIFY_LAST_DIGEST, '');
      return typeof raw === 'string' ? raw : '';
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'lastDigestDate failed: %{public}d', error.code);
      return '';
    }
  }

  /** 记录最近一次摘要日期（YYYY-MM-DD），保证当天不再重复发送。 */
  setLastDigestDate(date: string): void {
    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(PreferencesConstants.KEY_NOTIFY_LAST_DIGEST, date);
      store.flush().catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'flush digest date failed: %{public}d', err.code);
      });
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setLastDigestDate failed: %{public}d', error.code);
    }
  }
}

/** 全局唯一实例。 */
export const notifyStore: NotifyStore = new NotifyStore();
