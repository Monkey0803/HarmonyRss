/*
 * RemoteSyncPlan.ets — 远端同步的纯逻辑（无 IO，可独立单测）。
 *
 * 订阅合并 / 冲突决策 / edit-tag 分批都与数据库和网络无关；
 * RemoteSyncService 直接复用这里的实现（并对外 re-export，保持契约）。
 */

import { EditTagOp, GReaderTags, OutboxItem, RemoteFeed, StateDecision } from '../../model/Remote';
import { FeedSource } from '../../model/Feed';

/** 订阅合并结果。 */
export class FeedMergeResult {
  feeds: FeedSource[];
  added: number;
  changed: boolean;

  constructor(feeds: FeedSource[], added: number, changed: boolean) {
    this.feeds = feeds;
    this.added = added;
    this.changed = changed;
  }
}

/** 地址归一（去掉末尾斜杠、忽略大小写）。 */
export function feedKey(url: string): string {
  let value: string = url.trim();
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value.toLowerCase();
}

/**
 * 合并远端订阅到本地：
 *   - 按地址归一化匹配，命中后只补标题 / 分组（不覆盖用户自定义标题）；
 *   - 本地独有订阅保留；
 *   - 远端重复地址只取第一条。
 */
export function mergeFeeds(local: FeedSource[], remote: RemoteFeed[]): FeedMergeResult {
  const result: FeedSource[] = local.slice();
  const index: Map<string, FeedSource> = new Map<string, FeedSource>();
  for (let i = 0; i < result.length; i += 1) {
    const key: string = feedKey(result[i].url);
    if (key.length > 0 && !index.has(key)) {
      index.set(key, result[i]);
    }
  }
  let added: number = 0;
  let changed: boolean = false;
  const seenRemote: Set<string> = new Set<string>();
  for (let i = 0; i < remote.length; i += 1) {
    const item: RemoteFeed = remote[i];
    const key: string = feedKey(item.url);
    if (key.length === 0 || seenRemote.has(key)) {
      continue;
    }
    seenRemote.add(key);
    const existing: FeedSource | undefined = index.get(key);
    if (existing !== undefined) {
      // 本地标题是自动生成的（等于地址）时才用远端标题；用户改过的不覆盖。
      if (item.title.length > 0 &&
        (existing.title.length === 0 || feedKey(existing.title) === feedKey(existing.url))) {
        existing.title = item.title;
        changed = true;
      }
      if (existing.group.length === 0 && item.group.length > 0) {
        existing.group = item.group;
        changed = true;
      }
      continue;
    }
    const title: string = item.title.length > 0 ? item.title : item.url;
    const feed: FeedSource = new FeedSource(item.url, title, item.url, '', item.group);
    result.push(feed);
    index.set(key, feed);
    added += 1;
    changed = true;
  }
  return new FeedMergeResult(result, added, changed);
}

/** 本地独有订阅：本地地址在远端订阅列表中找不到（按归一化 URL 比较）。 */
export function localOnlyFeeds(local: FeedSource[], remote: RemoteFeed[]): FeedSource[] {
  const remoteKeys: Set<string> = new Set<string>();
  for (let i = 0; i < remote.length; i += 1) {
    const key: string = feedKey(remote[i].url);
    if (key.length > 0) {
      remoteKeys.add(key);
    }
  }
  const result: FeedSource[] = [];
  for (let i = 0; i < local.length; i += 1) {
    const key: string = feedKey(local[i].url);
    if (key.length === 0 || !remoteKeys.has(key)) {
      result.push(local[i]);
    }
  }
  return result;
}

/**
 * 冲突决策（push-first）：待同步队列里的字段以本地为准；否则采用远端值。
 * 阅读进度不参与远端同步，由调用方保留本地值。
 */
export function decideState(localRead: boolean, localStarred: boolean, remoteRead: boolean,
  remoteStarred: boolean, inOutbox: boolean): StateDecision {
  if (inOutbox) {
    return new StateDecision(localRead, localStarred);
  }
  return new StateDecision(remoteRead, remoteStarred);
}

/** 一条待同步项 → edit-tag 操作（无远端映射 / 无实际变更时返回 undefined）。 */
function toEditTagOp(item: OutboxItem, remoteId: string | undefined): EditTagOp | undefined {
  if (remoteId === undefined || remoteId.length === 0) {
    return undefined;
  }
  const add: string[] = [];
  const remove: string[] = [];
  if (item.setRead) {
    if (item.readValue) {
      add.push(GReaderTags.READ);
    } else {
      remove.push(GReaderTags.READ);
    }
  }
  if (item.setStarred) {
    if (item.starredValue) {
      add.push(GReaderTags.STARRED);
    } else {
      remove.push(GReaderTags.STARRED);
    }
  }
  if (add.length === 0 && remove.length === 0) {
    return undefined;
  }
  return new EditTagOp(remoteId, add, remove);
}

/** 把待同步项按批切分。无远端映射 / 无实际变更的条目被跳过。 */
export function buildEditTagBatches(items: OutboxItem[], remoteIds: Map<string, string>,
  batchSize: number): EditTagOp[][] {
  const batches: EditTagOp[][] = [];
  if (batchSize <= 0) {
    return batches;
  }
  let current: EditTagOp[] = [];
  for (let i = 0; i < items.length; i += 1) {
    const item: OutboxItem = items[i];
    const op: EditTagOp | undefined = toEditTagOp(item, remoteIds.get(item.articleId));
    if (op === undefined) {
      continue;
    }
    current.push(op);
    if (current.length >= batchSize) {
      batches.push(current);
      current = [];
    }
  }
  if (current.length > 0) {
    batches.push(current);
  }
  return batches;
}
