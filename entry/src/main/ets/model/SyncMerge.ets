/* Deterministic record and field conflict resolution. */
import { SyncKinds, SyncRecord, SyncField, ArticleStatePayload } from './SyncModels';
import { decodeArticleStatePayload, encodeArticleStatePayload } from './SyncPayloadCodec';

/**
 * 浅层比较两份 payload，返回「合并结果与远端不同」的键（排序去重）。
 * 非对象 / 解析失败的 payload 返回空数组：详情宁可不显示，也不能因为脏数据中断同步。
 */
export function changedPayloadFields(remotePayload: string, mergedPayload: string): string[] {
  if (remotePayload === mergedPayload || remotePayload.length === 0 || mergedPayload.length === 0) {
    return [];
  }
  let remote: Record<string, Object>;
  let merged: Record<string, Object>;
  try {
    remote = JSON.parse(remotePayload) as Record<string, Object>;
    merged = JSON.parse(mergedPayload) as Record<string, Object>;
  } catch (err) {
    return [];
  }
  if (typeof remote !== 'object' || typeof merged !== 'object' || remote === null || merged === null) {
    return [];
  }
  const fields: string[] = [];
  const keys: string[] = Object.keys(merged);
  for (let i = 0; i < keys.length; i += 1) {
    const key: string = keys[i];
    const remoteValue: Object = remote[key];
    const mergedValue: Object = merged[key];
    if (remoteValue === mergedValue) {
      continue;
    }
    if (JSON.stringify(remoteValue) !== JSON.stringify(mergedValue)) {
      fields.push(key);
    }
  }
  fields.sort();
  return fields;
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
