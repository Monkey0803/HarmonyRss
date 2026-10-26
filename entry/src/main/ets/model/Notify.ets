/*
 * Notify.ets — 通知增强的领域模型。
 *
 * 只有数据结构，不含判断逻辑：
 *   - NotifyPolicy：全局策略（免打扰 / 摘要 / 关键词）；
 *   - NotifyQueueItem：免打扰期间入队的待通知项；
 *   - NotifyItem：一次发布里的单条通知（文章 + 分组名 + 稳定通知 id）；
 *   - NotifyPlan：一次发布规划结果（逐条项 + 每源溢出数 + 总数）。
 * 判断逻辑在 service/NotifyPolicy.ets，偏好读写在 service/NotifyStore.ets。
 */

import { Article } from './Feed';

/** 通知策略默认值：AppSettings 字段、NotifyStore 回退、NotifyPolicy 构造三处共用，避免各写一份。 */
export class NotifyDefaults {
  /** 免打扰默认开启。 */
  static readonly DND_ENABLED: boolean = true;
  /** 默认开始 23:00（当天第 1380 分钟）。 */
  static readonly DND_START: number = 1380;
  /** 默认结束 08:00（当天第 480 分钟）。 */
  static readonly DND_END: number = 480;
  /** 每日摘要默认关闭。 */
  static readonly DIGEST_ENABLED: boolean = false;
  /** 每日摘要默认 20:00。 */
  static readonly DIGEST_HOUR: number = 20;
}

/**
 * 通知策略（全局）。
 * 免打扰用「当天第几分钟」表示，天然支持跨午夜；起止相同视为关闭。
 */
export class NotifyPolicy {
  /** 免打扰开关。 */
  dndEnabled: boolean;
  /** 免打扰开始（0–1439）。 */
  dndStart: number;
  /** 免打扰结束（0–1439）。 */
  dndEnd: number;
  /** 每日摘要开关。 */
  digestEnabled: boolean;
  /** 每日摘要触发小时（0–23）。 */
  digestHour: number;
  /** 关键词列表（空数组 = 不按关键词过滤）。 */
  keywords: string[];

  constructor(dndEnabled: boolean = NotifyDefaults.DND_ENABLED,
    dndStart: number = NotifyDefaults.DND_START,
    dndEnd: number = NotifyDefaults.DND_END,
    digestEnabled: boolean = NotifyDefaults.DIGEST_ENABLED,
    digestHour: number = NotifyDefaults.DIGEST_HOUR,
    keywords: string[] = []) {
    this.dndEnabled = dndEnabled;
    this.dndStart = dndStart;
    this.dndEnd = dndEnd;
    this.digestEnabled = digestEnabled;
    this.digestHour = digestHour;
    this.keywords = keywords;
  }
}

/** 免打扰期间的待通知队列项（按 at 升序排列）。 */
export class NotifyQueueItem {
  /** 文章 id（去重键）。 */
  articleId: string;
  /** 所属订阅源 id（补发时按源分组用）。 */
  feedId: string;
  /** 入队时间戳（毫秒）。 */
  at: number;

  constructor(articleId: string, feedId: string, at: number) {
    this.articleId = articleId;
    this.feedId = feedId;
    this.at = at;
  }
}

/** 一次发布里的单条通知。 */
export class NotifyItem {
  /** 作用对象。 */
  article: Article;
  /** 系统通知分组名（`feed_<feedId>`，同源共享，可展开）。 */
  groupName: string;
  /** 稳定通知 id（由文章 id 派生，重复发布只更新同一条）。 */
  notificationId: number;

  constructor(article: Article, groupName: string, notificationId: number) {
    this.article = article;
    this.groupName = groupName;
    this.notificationId = notificationId;
  }
}

/**
 * 一次发布的规划结果。
 * `overflowByFeed` 只包含「被限流砍掉」的源（值 = 该源被砍掉的篇数），用于发「还有 N 篇」聚合。
 */
export class NotifyPlan {
  /** 逐条通知（已按每源 / 总量上限裁剪）。 */
  items: NotifyItem[];
  /** feedId → 该源被砍掉的篇数（仅 > 0 的源）。 */
  overflowByFeed: Map<string, number>;
  /** 逐条通知条数（= items.length）。 */
  total: number;

  constructor(items: NotifyItem[], overflowByFeed: Map<string, number>) {
    this.items = items;
    this.overflowByFeed = overflowByFeed;
    this.total = items.length;
  }
}
