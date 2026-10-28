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
}

/** 实体键前缀（key = 前缀 + 稳定 id）。 */
export class SyncKeys {
  static readonly FEED: string = 'feed:';
  static readonly ARTICLE_STATE: string = 'article:';

  /** 订阅源键：用归一化后的订阅地址，同址不同写法不会分裂成两条。 */
  static feedKey(normalizedUrl: string): string {
    return SyncKeys.FEED + normalizedUrl;
  }

  /** 文章状态键：用本地文章 id（由订阅地址 + 链接生成，天然稳定）。 */
  static articleStateKey(articleId: string): string {
    return SyncKeys.ARTICLE_STATE + articleId;
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
