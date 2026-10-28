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

/** 字段合并：时间新者胜；同一时间时布尔取 true、进度取较大值，其余保留本地。 */
export function mergeField(local: SyncField, remote: SyncField): SyncField {
  if (local.at > remote.at) {
    return local;
  }
  if (remote.at > local.at) {
    return remote;
  }
  if (local.value === remote.value) {
    return local;
  }
  const localTrue: boolean = local.value === '1';
  const remoteTrue: boolean = remote.value === '1';
  if (localTrue !== remoteTrue) {
    // 平局时「已读 / 收藏」优先，避免旧快照把状态回滚。
    return localTrue ? local : remote;
  }
  const localNumber: number = Number(local.value);
  const remoteNumber: number = Number(remote.value);
  if (Number.isFinite(localNumber) && Number.isFinite(remoteNumber) && localNumber !== remoteNumber) {
    return localNumber > remoteNumber ? local : remote;
  }
  return local;
}

/** 合并文章状态：逐字段取各自最新的值。 */
export function mergeArticleState(local: ArticleStatePayload,
  remote: ArticleStatePayload): ArticleStatePayload {
  return new ArticleStatePayload(
    mergeField(local.read, remote.read),
    mergeField(local.starred, remote.starred),
    mergeField(local.saved, remote.saved),
    mergeField(local.progress, remote.progress));
}

/** 载荷里最新的时间戳（记录级 updatedAt 用）。 */
export function latestFieldAt(payload: ArticleStatePayload): number {
  return Math.max(payload.read.at, payload.starred.at, payload.saved.at, payload.progress.at);
}

/** 记录级后写胜出：时间相同按 origin 字典序，保证两端选出同一个。 */
export function pickNewer(local: SyncRecord, remote: SyncRecord): SyncRecord {
  if (local.updatedAt > remote.updatedAt) {
    return local;
  }
  if (remote.updatedAt > local.updatedAt) {
    return remote;
  }
  if (local.origin === remote.origin) {
    return local;
  }
  return local.origin > remote.origin ? local : remote;
}

/** 订阅源载荷编解码（纯函数）。 */
export function encodeFeedPayload(payload: FeedPayload): string {
  return JSON.stringify(payload);
}

export function decodeFeedPayload(text: string): FeedPayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: FeedPayload = JSON.parse(text) as FeedPayload;
    if (typeof payload.url !== 'string' || payload.url.length === 0) {
      return undefined;
    }
    return new FeedPayload(
      payload.url,
      typeof payload.title === 'string' ? payload.title : '',
      typeof payload.siteUrl === 'string' ? payload.siteUrl : '',
      typeof payload.group === 'string' ? payload.group : '',
      payload.enabled !== false);
  } catch (err) {
    return undefined;
  }
}

/** 文章状态载荷编解码（纯函数；缺字段退回 0 / false，不阻断合并）。 */
export function encodeArticleStatePayload(payload: ArticleStatePayload): string {
  return JSON.stringify(payload);
}

function normalizeField(raw: SyncField | undefined, fallback: string): SyncField {
  if (raw === undefined || raw === null || typeof raw.value !== 'string') {
    return new SyncField(fallback, 0);
  }
  const at: number = typeof raw.at === 'number' && Number.isFinite(raw.at) && raw.at > 0 ? raw.at : 0;
  return new SyncField(raw.value, at);
}

export function decodeArticleStatePayload(text: string): ArticleStatePayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: ArticleStatePayload = JSON.parse(text) as ArticleStatePayload;
    return new ArticleStatePayload(
      normalizeField(payload.read, '0'),
      normalizeField(payload.starred, '0'),
      normalizeField(payload.saved, '0'),
      normalizeField(payload.progress, '0'));
  } catch (err) {
    return undefined;
  }
}

function textOf(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}

function numberOf(value: number | undefined): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

/** 高亮载荷编解码（纯函数；缺 id / articleId 视为无效，不参与应用）。 */
export function encodeHighlightPayload(payload: HighlightPayload): string {
  return JSON.stringify(payload);
}

export function decodeHighlightPayload(text: string): HighlightPayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: HighlightPayload = JSON.parse(text) as HighlightPayload;
    const id: string = textOf(payload.id);
    const articleId: string = textOf(payload.articleId);
    if (id.length === 0 || articleId.length === 0) {
      return undefined;
    }
    return new HighlightPayload(id, articleId, textOf(payload.quote), textOf(payload.note),
      textOf(payload.color), numberOf(payload.createdAt), textOf(payload.anchorText),
      numberOf(payload.anchorRatio));
  } catch (err) {
    return undefined;
  }
}

/** 标签载荷编解码（纯函数）。 */
export function encodeTagPayload(payload: TagPayload): string {
  return JSON.stringify(payload);
}

export function decodeTagPayload(text: string): TagPayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: TagPayload = JSON.parse(text) as TagPayload;
    const name: string = textOf(payload.name);
    if (name.length === 0) {
      return undefined;
    }
    return new TagPayload(name);
  } catch (err) {
    return undefined;
  }
}

/** 文章 ↔ 标签关联载荷编解码（纯函数）。 */
export function encodeArticleTagPayload(payload: ArticleTagPayload): string {
  return JSON.stringify(payload);
}

export function decodeArticleTagPayload(text: string): ArticleTagPayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: ArticleTagPayload = JSON.parse(text) as ArticleTagPayload;
    const articleId: string = textOf(payload.articleId);
    const nameKey: string = textOf(payload.nameKey);
    const name: string = textOf(payload.name);
    if (articleId.length === 0 || nameKey.length === 0 || name.length === 0) {
      return undefined;
    }
    return new ArticleTagPayload(articleId, nameKey, name);
  } catch (err) {
    return undefined;
  }
}

function stringArrayOf(value: string[] | undefined): string[] {
  const result: string[] = [];
  if (value === undefined || value === null) {
    return result;
  }
  for (let i = 0; i < value.length; i += 1) {
    const item: string = value[i];
    if (typeof item === 'string' && item.length > 0) {
      result.push(item);
    }
  }
  return result;
}

/** 智能文件夹载荷编解码。 */
export function encodeSmartFolderPayload(payload: SmartFolderPayload): string {
  return JSON.stringify(payload);
}

export function decodeSmartFolderPayload(text: string): SmartFolderPayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: SmartFolderPayload = JSON.parse(text) as SmartFolderPayload;
    const name: string = textOf(payload.name);
    if (name.length === 0) {
      return undefined;
    }
    return new SmartFolderPayload(name, textOf(payload.query));
  } catch (err) {
    return undefined;
  }
}

/** 规则载荷编解码（数组字段逐项过滤，脏值直接丢弃）。 */
export function encodeRulePayload(payload: RulePayload): string {
  return JSON.stringify(payload);
}

export function decodeRulePayload(text: string): RulePayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: RulePayload = JSON.parse(text) as RulePayload;
    const name: string = textOf(payload.name);
    if (name.length === 0) {
      return undefined;
    }
    return new RulePayload(name, payload.enabled === true,
      stringArrayOf(payload.keywords), stringArrayOf(payload.fields),
      stringArrayOf(payload.actions), stringArrayOf(payload.feedKeys),
      stringArrayOf(payload.tagNames));
  } catch (err) {
    return undefined;
  }
}

/** 分享模板载荷编解码。 */
export function encodeTemplatePayload(payload: TemplatePayload): string {
  return JSON.stringify(payload);
}

export function decodeTemplatePayload(text: string): TemplatePayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: TemplatePayload = JSON.parse(text) as TemplatePayload;
    const name: string = textOf(payload.name);
    if (name.length === 0) {
      return undefined;
    }
    return new TemplatePayload(name, textOf(payload.content));
  } catch (err) {
    return undefined;
  }
}

/** 两条记录是否等价（用于判断「合并结果是否需要回推」）。 */
export function isSameRecord(left: SyncRecord, right: SyncRecord): boolean {
  return left.key === right.key && left.kind === right.kind &&
    left.updatedAt === right.updatedAt && left.deleted === right.deleted &&
    left.payload === right.payload && left.origin === right.origin;
}

/**
 * 合并两端记录：
 *   - 文章状态走字段级合并（删除状态按记录级比较）；
 *   - 其余实体（订阅源）整体后写胜出。
 * 返回的 origin 取胜出者，便于下一轮平局继续收敛。
 */
export function mergeRecord(local: SyncRecord, remote: SyncRecord): SyncRecord {
  if (local.kind === SyncKinds.ARTICLE_STATE && remote.kind === SyncKinds.ARTICLE_STATE &&
    !local.deleted && !remote.deleted) {
    const localPayload: ArticleStatePayload | undefined = decodeArticleStatePayload(local.payload);
    const remotePayload: ArticleStatePayload | undefined = decodeArticleStatePayload(remote.payload);
    if (localPayload !== undefined && remotePayload !== undefined) {
      const merged: ArticleStatePayload = mergeArticleState(localPayload, remotePayload);
      const winner: SyncRecord = pickNewer(local, remote);
      return new SyncRecord(local.key, local.kind, latestFieldAt(merged), false,
        encodeArticleStatePayload(merged), winner.origin);
    }
  }
  return pickNewer(local, remote);
}
