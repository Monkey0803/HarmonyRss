/*
 * NotifyPolicy.ets — 通知策略的纯判断逻辑（不碰系统 API，可单测）。
 *
 *   inDnd          免打扰判定（支持跨午夜；起止相同视为关闭）
 *   matchesKeywords 标题 / 摘要包含任一关键词（大小写不敏感；空列表通过）
 *   filter         已读 / 隐藏 / 重复项 → 源开关 → 全局开关 → 关键词
 *   plan           按源分组 + 每源 / 总量限流，产出 NotifyPlan
 *   digestDue      每日摘要是否到期（开启、到点、当天未发过）
 *
 * 归一化辅助（clamp / normalizeKeywords / decodeKeywords）也放这里：
 * SettingsStore 与 NotifyStore 共用同一套规则，避免两处漂移。
 */

import { Article, FeedSource } from '../model/Feed';
import { TriState } from '../common/constants/SettingsConstants';
import { CommonConstants } from '../common/constants/CommonConstants';
import { NotifyDefaults, NotifyItem, NotifyPlan, NotifyPolicy } from '../model/Notify';
import { appSettings } from '../model/AppSettings';

/** 一天分钟数。 */
const MINUTES_PER_DAY: number = 1440;
/** 系统通知分组名前缀：同一源的条目共享 group，系统可展开。 */
const GROUP_PREFIX: string = 'feed_';

// ---- 归一化辅助（SettingsStore / NotifyStore / 策略共用） ----

/** 两位补零。 */
function pad2(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

/** 「当天第几分钟」归一：非法值退回 fallback，再夹到 0–1439。 */
export function clampMinuteOfDay(value: number, fallback: number): number {
  const fallbackValue: number = Number.isFinite(fallback) ? fallback : 0;
  const base: number = Math.min(MINUTES_PER_DAY - 1, Math.max(0, Math.round(fallbackValue)));
  if (!Number.isFinite(value)) {
    return base;
  }
  const rounded: number = Math.round(value);
  return Math.min(MINUTES_PER_DAY - 1, Math.max(0, rounded));
}

/** 「当天第几分钟」循环归一（用于判定时刻：1440 → 0）。 */
export function normalizeMinuteOfDay(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  const rounded: number = Math.round(value) % MINUTES_PER_DAY;
  return rounded < 0 ? rounded + MINUTES_PER_DAY : rounded;
}

/** 摘要小时归一：0–23，非法值退回 fallback。 */
export function clampDigestHour(value: number, fallback: number): number {
  const fallbackValue: number = Number.isFinite(fallback) ? Math.round(fallback) : NotifyDefaults.DIGEST_HOUR;
  const base: number = Math.min(23, Math.max(0, fallbackValue));
  if (!Number.isFinite(value)) {
    return base;
  }
  return Math.min(23, Math.max(0, Math.round(value)));
}

/** 关键词归一：trim → 去空 → 大小写不敏感去重 → 截到上限；保持原始大小写展示。 */
export function normalizeKeywords(list: string[]): string[] {
  const result: string[] = [];
  for (let i = 0; i < list.length && result.length < CommonConstants.NOTIFY_KEYWORD_MAX; i += 1) {
    const item: string = list[i];
    if (typeof item !== 'string') {
      continue;
    }
    const text: string = item.trim();
    if (text.length === 0) {
      continue;
    }
    const key: string = text.toLowerCase();
    let exists: boolean = false;
    for (let j = 0; j < result.length; j += 1) {
      if (result[j].toLowerCase() === key) {
        exists = true;
        break;
      }
    }
    if (!exists) {
      result.push(text);
    }
  }
  return result;
}

/** 解码关键词 JSON（脏数据 / 非数组 / 非法项一律丢弃，不让坏值影响通知）。 */
export function decodeKeywords(text: string): string[] {
  if (text.length === 0) {
    return [];
  }
  try {
    const values: string[] = JSON.parse(text) as string[];
    return normalizeKeywords(values);
  } catch (err) {
    return [];
  }
}

/** 编码关键词 JSON（调用方保证已归一）。 */
export function encodeKeywords(list: string[]): string {
  return JSON.stringify(normalizeKeywords(list));
}

/** 策略归一：时间夹到合法范围、关键词去重截断。 */
export function normalizePolicy(policy: NotifyPolicy): NotifyPolicy {
  return new NotifyPolicy(
    policy.dndEnabled,
    clampMinuteOfDay(policy.dndStart, NotifyDefaults.DND_START),
    clampMinuteOfDay(policy.dndEnd, NotifyDefaults.DND_END),
    policy.digestEnabled,
    clampDigestHour(policy.digestHour, NotifyDefaults.DIGEST_HOUR),
    normalizeKeywords(policy.keywords));
}

// ---- 时间辅助 ----

/** 时间戳 → 当天第几分钟（本地时区）。 */
export function minutesOfDay(ts: number): number {
  const date: Date = new Date(ts);
  return date.getHours() * 60 + date.getMinutes();
}

/** 时间戳 → 本地日期键 `YYYY-MM-DD`（摘要「当天最多一条」用）。 */
export function localDateKey(ts: number): string {
  const date: Date = new Date(ts);
  return date.getFullYear().toString() + '-' + pad2(date.getMonth() + 1) + '-' + pad2(date.getDate());
}

// ---- 策略判定 ----

/**
 * 是否处于免打扰时段。
 * 支持跨午夜（start > end）；start === end 视为关闭；分钟数自动循环归一。
 */
export function inDnd(policy: NotifyPolicy, minutesOfDayValue: number): boolean {
  if (!policy.dndEnabled) {
    return false;
  }
  const start: number = clampMinuteOfDay(policy.dndStart, NotifyDefaults.DND_START);
  const end: number = clampMinuteOfDay(policy.dndEnd, NotifyDefaults.DND_END);
  if (start === end) {
    return false;
  }
  const minute: number = normalizeMinuteOfDay(minutesOfDayValue);
  if (start < end) {
    return minute >= start && minute < end;
  }
  // 跨午夜：例如 23:00–08:00，命中 [start, 24:00) 或 [0, end)。
  return minute >= start || minute < end;
}

/** 关键词匹配：标题 / 摘要包含任一关键词即通过；关键词为空表示不过滤。 */
export function matchesKeywords(article: Article, keywords: string[]): boolean {
  const list: string[] = normalizeKeywords(keywords);
  if (list.length === 0) {
    return true;
  }
  const title: string = article.title.toLowerCase();
  const summary: string = article.summary.toLowerCase();
  for (let i = 0; i < list.length; i += 1) {
    const keyword: string = list[i].toLowerCase();
    if (title.indexOf(keyword) >= 0 || summary.indexOf(keyword) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 单源是否允许通知（三态：on / off / global）。
 * global 取全局开关 appSettings.notifyNewArticles —— 与 RssWorkScheduler 现有判定一致。
 */
export function isFeedNotifyEnabled(feed: FeedSource): boolean {
  if (feed.notify === TriState.ON) {
    return true;
  }
  if (feed.notify === TriState.OFF) {
    return false;
  }
  return appSettings.notifyNewArticles;
}

/**
 * 过滤待通知文章（顺序保持输入的先后）。
 * 依次排除：已读 / 隐藏 / 跨源重复项（canonicalId 非空）→ 源不存在或已停用 → 源通知关闭 → 关键词不命中。
 * 源已删除（feeds 里找不到）时不通知：文章只是历史残留，提醒它已无意义。
 */
export function filter(articles: Article[], feeds: FeedSource[], policy: NotifyPolicy): Article[] {
  const result: Article[] = [];
  const byId: Map<string, FeedSource> = new Map<string, FeedSource>();
  for (let i = 0; i < feeds.length; i += 1) {
    byId.set(feeds[i].id, feeds[i]);
  }
  for (let i = 0; i < articles.length; i += 1) {
    const article: Article = articles[i];
    if (article.read || article.hidden || article.canonicalId.length > 0) {
      continue;
    }
    const feed: FeedSource | undefined = byId.get(article.feedId);
    if (feed === undefined || !feed.enabled) {
      continue;
    }
    if (!isFeedNotifyEnabled(feed)) {
      continue;
    }
    if (!matchesKeywords(article, policy.keywords)) {
      continue;
    }
    result.push(article);
  }
  return result;
}

/**
 * 稳定通知 id：由文章 id 派生（同一篇文章重复规划得到同一个 id，重复发布只更新同一条）。
 * 取值 1..2147483646，避免 0（部分系统实现里 0 有特殊含义）。
 */
export function stableNotificationId(articleId: string): number {
  let hash: number = 0;
  for (let i = 0; i < articleId.length; i += 1) {
    hash = (hash * 31 + articleId.charCodeAt(i)) % 2147483647;
  }
  return hash === 0 ? 1 : hash;
}

/** 同源通知分组名。 */
export function groupNameOf(feedId: string): string {
  return GROUP_PREFIX + feedId;
}

/**
 * 规划一次发布：按来源分组计数，每源最多 maxPerFeed 条、总量最多 maxTotal 条，
 * 被砍掉的条数按源累计到 overflowByFeed（用于发「还有 N 篇」聚合）。
 * 上限 <= 0 视为不发逐条通知（全部计入溢出）。
 */
export function plan(items: Article[], maxPerFeed: number, maxTotal: number): NotifyPlan {
  const accepted: NotifyItem[] = [];
  const overflow: Map<string, number> = new Map<string, number>();
  const perFeedCount: Map<string, number> = new Map<string, number>();
  const perLimit: number = maxPerFeed > 0 ? Math.floor(maxPerFeed) : 0;
  const totalLimit: number = maxTotal > 0 ? Math.floor(maxTotal) : 0;
  for (let i = 0; i < items.length; i += 1) {
    const article: Article = items[i];
    const feedId: string = article.feedId;
    const used: number = perFeedCount.get(feedId) ?? 0;
    if (accepted.length >= totalLimit || used >= perLimit) {
      overflow.set(feedId, (overflow.get(feedId) ?? 0) + 1);
      continue;
    }
    perFeedCount.set(feedId, used + 1);
    accepted.push(new NotifyItem(article, groupNameOf(feedId), stableNotificationId(article.id)));
  }
  return new NotifyPlan(accepted, overflow);
}

/**
 * 每日摘要是否到期：摘要开启 + 当前小时已到设定值 + 今天还没发过。
 * 不追求准点：由「回到前台 / 后台任务结束」触发检查，所以只判断「已过点」。
 */
export function digestDue(policy: NotifyPolicy, now: number, lastDigestDate: string): boolean {
  if (!policy.digestEnabled) {
    return false;
  }
  const hour: number = new Date(now).getHours();
  const target: number = clampDigestHour(policy.digestHour, NotifyDefaults.DIGEST_HOUR);
  if (hour < target) {
    return false;
  }
  return lastDigestDate !== localDateKey(now);
}
