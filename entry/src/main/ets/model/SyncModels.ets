/*
 * Sync.ets — 云同步的记录模型与合并规则（纯逻辑，可单测）。
 *
 * 同步内核与传输无关：`SyncRecord` 是唯一在本地库 / 后端之间流动的单位。
 *   - 订阅源（feed）：整条记录按 updatedAt 后写胜出；
 *   - 文章状态（articleState）：载荷里 read / starred / saved / progress 各自带时间戳，
 *     合并按字段取各自最新值 —— 否则「B 端只标收藏」会把「A 端的已读」整条覆盖回去。
 *
 * 删除用墓碑（deleted = true）参与同一套比较，不做物理删除：删除也要能传播到另一端。
 */

/** 同步实体类型。 */
export class SyncKinds {
  static readonly FEED: string = 'feed';
  static readonly ARTICLE_STATE: string = 'articleState';
  /** 正文标注（引文 + 备注 + 配色）。 */
  static readonly HIGHLIGHT: string = 'highlight';
  /** 标签定义（按归一化名称做键）。 */
  static readonly TAG: string = 'tag';
  /** 文章 ↔ 标签关联。 */
  static readonly ARTICLE_TAG: string = 'articleTag';
  /** 应用设置（白名单键的扁平 JSON，单条记录整体后写胜出）。 */
  static readonly SETTINGS: string = 'settings';
  /** 智能文件夹（保存的检索条件）。 */
  static readonly SMART_FOLDER: string = 'smartFolder';
  /** 本地规则引擎的规则。 */
  static readonly RULE: string = 'rule';
  /** 分享模板。 */
  static readonly TEMPLATE: string = 'template';
  /** 独立保存的网页（稍后读）：只同步元数据，正文各端按需重新提取。 */
  static readonly WEB_PAGE: string = 'webPage';
}

/** 实体键前缀（key = 前缀 + 稳定 id）。 */
export class SyncKeys {
  static readonly FEED: string = 'feed:';
  static readonly ARTICLE_STATE: string = 'article:';
  static readonly HIGHLIGHT: string = 'highlight:';
  static readonly TAG: string = 'tag:';
  static readonly ARTICLE_TAG: string = 'articleTag:';
  /** 智能文件夹 / 规则 / 分享模板（按名称做键，两端同名收敛）。 */
  static readonly SMART_FOLDER: string = 'smartFolder:';
  static readonly RULE: string = 'rule:';
  static readonly TEMPLATE: string = 'template:';
  /** 设置只有一份，用固定键。 */
  static readonly SETTINGS: string = 'setting:app';
  /** 独立保存的网页：按归一化 URL 做键，两端同一网页收敛为一条。 */
  static readonly WEB_PAGE: string = 'webPage:';

  /** 名称类实体的键：去首尾空白 + 小写（改名 = 删旧键 + 建新键）。 */
  static nameKey(raw: string): string {
    return raw.trim().toLowerCase();
  }

  /** 订阅源键：用归一化后的订阅地址，同址不同写法不会分裂成两条。 */
  static feedKey(normalizedUrl: string): string {
    return SyncKeys.FEED + normalizedUrl;
  }

  /** 文章状态键：用本地文章 id（由订阅地址 + 链接生成，天然稳定）。 */
  static articleStateKey(articleId: string): string {
    return SyncKeys.ARTICLE_STATE + articleId;
  }

  /** 保存网页键：用归一化 URL（两端对同一网页得到同一个键）。 */
  static webPageKey(urlKey: string): string {
    return SyncKeys.WEB_PAGE + urlKey;
  }

  /** 高亮键：高亮 id 在本机生成，跨设备不会重复。 */
  static highlightKey(id: string): string {
    return SyncKeys.HIGHLIGHT + id;
  }

  /** 标签键：用归一化名称（小写），两端同名标签会自动收敛成一条。 */
  static tagKey(nameKey: string): string {
    return SyncKeys.TAG + nameKey;
  }

  /** 文章 ↔ 标签关联键：标签 + 文章，两边都是稳定标识。 */
  static articleTagKey(nameKey: string, articleId: string): string {
    return SyncKeys.ARTICLE_TAG + nameKey + '|' + articleId;
  }

  static smartFolderKey(nameKey: string): string {
    return SyncKeys.SMART_FOLDER + nameKey;
  }

  static ruleKey(nameKey: string): string {
    return SyncKeys.RULE + nameKey;
  }

  static templateKey(nameKey: string): string {
    return SyncKeys.TEMPLATE + nameKey;
  }
}

/** 一端的同步记录。 */
export class SyncRecord {
  readonly key: string;
  readonly kind: string;
  /** 最后修改时间（毫秒）。合并时越大越新。 */
  readonly updatedAt: number;
  /** 墓碑：true 表示这条已被删除（仍需同步出去）。 */
  readonly deleted: boolean;
  /** 实体载荷（JSON 字符串，由各 kind 的编解码函数负责）。 */
  readonly payload: string;
  /** 修改来源节点 id：时间相同时用来打破平局，保证两端收敛到同一结果。 */
  readonly origin: string;

  constructor(key: string, kind: string, updatedAt: number, deleted: boolean,
    payload: string, origin: string) {
    this.key = key;
    this.kind = kind;
    this.updatedAt = updatedAt;
    this.deleted = deleted;
    this.payload = payload;
    this.origin = origin;
  }
}

/** 带时间戳的字段值（文章状态用）。 */
export class SyncField {
  readonly value: string;
  readonly at: number;

  constructor(value: string, at: number) {
    this.value = value;
    this.at = at;
  }
}

/** 订阅源载荷。 */
export class FeedPayload {
  readonly url: string;
  readonly title: string;
  readonly siteUrl: string;
  readonly group: string;
  readonly enabled: boolean;

  constructor(url: string, title: string, siteUrl: string, group: string, enabled: boolean) {
    this.url = url;
    this.title = title;
    this.siteUrl = siteUrl;
    this.group = group;
    this.enabled = enabled;
  }
}

/** 文章状态载荷：每个字段各带自己的修改时间。 */
export class ArticleStatePayload {
  readonly read: SyncField;
  readonly starred: SyncField;
  readonly saved: SyncField;
  /** 阅读进度比例（0–1）的字符串形式，便于与其它字段共用合并逻辑。 */
  readonly progress: SyncField;

  constructor(read: SyncField, starred: SyncField, saved: SyncField, progress: SyncField) {
    this.read = read;
    this.starred = starred;
    this.saved = saved;
    this.progress = progress;
  }
}

/**
 * 独立保存网页的载荷：只放元数据。
 * 正文（reader_html）可能是几百 KB，跨端同步没有意义 —— 另一端打开时按需重新提取。
 */
export class WebPagePayload {
  readonly url: string;
  /** 用户在预览里确认过的标题（空则由对端回落为来源名）。 */
  readonly title: string;
  /** 来源名（保存时的站点名）。 */
  readonly source: string;
  /** 列表摘要（短文本，便于对端列表直接显示）。 */
  readonly summary: string;
  /** 保存时间（毫秒）；两端合并只用于排序，不参与冲突判定。 */
  readonly savedAt: number;

  constructor(url: string, title: string, source: string, summary: string, savedAt: number) {
    this.url = url;
    this.title = title;
    this.source = source;
    this.summary = summary;
    this.savedAt = savedAt;
  }
}

/** 高亮载荷：整条记录后写胜出（改备注 / 改配色都算一次修改）。 */
export class HighlightPayload {
  readonly id: string;
  readonly articleId: string;
  readonly quote: string;
  readonly note: string;
  readonly color: string;
  readonly createdAt: number;
  readonly anchorText: string;
  readonly anchorRatio: number;

  constructor(id: string, articleId: string, quote: string, note: string, color: string,
    createdAt: number, anchorText: string, anchorRatio: number) {
    this.id = id;
    this.articleId = articleId;
    this.quote = quote;
    this.note = note;
    this.color = color;
    this.createdAt = createdAt;
    this.anchorText = anchorText;
    this.anchorRatio = anchorRatio;
  }
}

/**
 * 标签载荷：只有展示名。
 *
 * 刻意不带创建时间 / 本地 id —— 它们各端不同，放进载荷会让差量采集每轮都判定「有变化」，
 * 两端来回覆盖（createdAt 在本地表里保留原值即可）。
 */
export class TagPayload {
  readonly name: string;

  constructor(name: string) {
    this.name = name;
  }
}

/** 文章 ↔ 标签关联载荷：带上标签展示名，应用时不必依赖标签记录先到。 */
export class ArticleTagPayload {
  readonly articleId: string;
  readonly nameKey: string;
  readonly name: string;

  constructor(articleId: string, nameKey: string, name: string) {
    this.articleId = articleId;
    this.nameKey = nameKey;
    this.name = name;
  }
}

/** 智能文件夹载荷：名称 + 检索语法（排序位是设备本地偏好，不同步）。 */
export class SmartFolderPayload {
  readonly name: string;
  readonly query: string;

  constructor(name: string, query: string) {
    this.name = name;
    this.query = query;
  }
}

/**
 * 规则载荷：名称 / 开关 / 关键词 / 字段 / 动作 + 订阅源与标签引用。
 *
 * 引用按**稳定标识**同步：订阅源用归一化 URL，标签用归一化名称 —— 本地 id 跨设备不可用。
 * 优先级与命中统计（priority / matchCount / lastHitAt）是本机执行状态，不进载荷，避免每轮都判脏。
 */
export class RulePayload {
  readonly name: string;
  readonly enabled: boolean;
  readonly keywords: string[];
  readonly fields: string[];
  readonly actions: string[];
  readonly feedKeys: string[];
  readonly tagNames: string[];

  constructor(name: string, enabled: boolean, keywords: string[], fields: string[],
    actions: string[], feedKeys: string[], tagNames: string[]) {
    this.name = name;
    this.enabled = enabled;
    this.keywords = keywords;
    this.fields = fields;
    this.actions = actions;
    this.feedKeys = feedKeys;
    this.tagNames = tagNames;
  }
}

/** 分享模板载荷：名称 + 正文（排序位不同步）。 */
export class TemplatePayload {
  readonly name: string;
  readonly content: string;

  constructor(name: string, content: string) {
    this.name = name;
    this.content = content;
  }
}

/** 一页拉取结果。 */
export class SyncPullPage {
  readonly records: SyncRecord[];
  /** 该页之后可推进到的游标；空串表示没拿到新记录。 */
  readonly cursor: string;

  constructor(records: SyncRecord[], cursor: string) {
    this.records = records;
    this.cursor = cursor;
  }
}

/** 推送结果：accepted 可以标干净，rejected 留待下次重试。 */
export class SyncPushResult {
  readonly accepted: string[];
  readonly rejected: string[];
  readonly errors: string[];

  constructor(accepted: string[], rejected: string[], errors: string[]) {
    this.accepted = accepted;
    this.rejected = rejected;
    this.errors = errors;
  }
}

/** 一次同步的摘要（供设置页展示）。 */
export class SyncSummary {
  /** 本次成功推送的条数。 */
  pushed: number;
  /** 本次从远端拉到并合并的条数。 */
  pulled: number;
  /** 其中真正发生冲突（两端都改过）的条数。 */
  conflicts: number;
  /** 同步结束后仍待推送的条数。 */
  pending: number;
  /** 完成时间；0 表示失败。 */
  at: number;
  /** 失败分类文案；空串表示成功。 */
  error: string;

  constructor(pushed: number, pulled: number, conflicts: number, pending: number,
    at: number, error: string) {
    this.pushed = pushed;
    this.pulled = pulled;
    this.conflicts = conflicts;
    this.pending = pending;
    this.at = at;
    this.error = error;
  }
}

/**
 * 一条「自动合并」的概要（设置页展示用）。
 * 只保留可定位的键与发生变化的字段名，不带完整 payload —— 冲突详情不该把正文塞进偏好库。
 */
export class SyncConflict {
  /** 同步记录键（如 `articleState:xxx`）。 */
  readonly key: string;
  /** 实体类型（见 SyncKinds）。 */
  readonly kind: string;
  /** 合并结果与远端不一致的字段名（浅层 JSON 键，已排序）；空数组表示整条以较新一端为准。 */
  readonly fields: string[];

  constructor(key: string, kind: string, fields: string[]) {
    this.key = key;
    this.kind = kind;
    this.fields = fields;
  }
}
