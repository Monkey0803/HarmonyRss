/*
 * GReaderBackend.ets — Google Reader API 的 RemoteBackend 适配器。
 *
 * 复用既有 GReaderClient / 解析层，行为与接入 Feedbin 前保持一致：
 *   - 认证：ClientLogin（login 自己负责网络 / 鉴权 / API 未开启分类）；
 *   - 文章：stream/contents + continuation，游标为毫秒时间戳；
 *   - 回写：edit-tag（按 add/remove 标签分组，失败退回逐条）。
 */

import { EditTagOp, GReaderTags, RemoteArticle, RemoteError, RemoteErrorCode, RemoteFeed, RemoteIdPage } from '../../model/Remote';
import { RemoteSyncConstants } from '../../common/constants/RssConstants';
import {
  GReaderClient,
  gReaderClient,
  isInsecureUrl,
  normalizeBaseUrl
} from './GReaderClient';
import {
  RemoteArticlePage,
  RemoteBackend,
  RemotePushResult,
  RemoteSession,
  RemoteStateChange
} from './RemoteBackend';

function codeOf(err: Object): RemoteErrorCode {
  return err instanceof RemoteError ? err.code : RemoteErrorCode.SERVER;
}

/** 中立变更 → GReader edit-tag 操作。 */
function toEditTagOp(change: RemoteStateChange): EditTagOp | undefined {
  const add: string[] = [];
  const remove: string[] = [];
  if (change.read === true) {
    add.push(GReaderTags.READ);
  } else if (change.read === false) {
    remove.push(GReaderTags.READ);
  }
  if (change.starred === true) {
    add.push(GReaderTags.STARRED);
  } else if (change.starred === false) {
    remove.push(GReaderTags.STARRED);
  }
  if (add.length === 0 && remove.length === 0) {
    return undefined;
  }
  return new EditTagOp(change.remoteId, add, remove);
}

export class GReaderBackend implements RemoteBackend {
  readonly serviceType: string = RemoteSyncConstants.SERVICE_TYPE_GREADER;
  readonly defaultBaseUrl: string = '';
  private readonly client: GReaderClient = gReaderClient;

  normalizeBaseUrl(input: string): string {
    return normalizeBaseUrl(input);
  }

  isInsecureUrl(value: string): boolean {
    return isInsecureUrl(value);
  }

  async authenticate(baseUrl: string, username: string, password: string): Promise<RemoteSession> {
    // 连接和重新认证都只走 ClientLogin：login 本身已能分类网络 / 鉴权 / API 未开启错误。
    const token: string = await this.client.login(baseUrl, username, password);
    return new RemoteSession(token);
  }

  async listSubscriptions(baseUrl: string, session: RemoteSession): Promise<RemoteFeed[]> {
    return this.client.fetchSubscriptions(baseUrl, session.token);
  }

  async fetchArticlePage(baseUrl: string, session: RemoteSession, feed: RemoteFeed,
    cursor: string, continuation: string, limit: number): Promise<RemoteArticlePage> {
    const page = await this.client.fetchContents(baseUrl, session.token, feed.url, continuation, limit);
    const current: number = Number.parseInt(cursor, 10);
    const currentCursor: number = Number.isNaN(current) ? 0 : current;
    let nextCursor: number = currentCursor;
    const items: RemoteArticle[] = [];
    for (let i = 0; i < page.items.length; i += 1) {
      const item: RemoteArticle = page.items[i];
      if (currentCursor > 0 && item.publishedAt > 0 && item.publishedAt <= currentCursor) {
        continue;
      }
      items.push(item);
      if (item.publishedAt > nextCursor) {
        nextCursor = item.publishedAt;
      }
    }
    const pageCursor: string = nextCursor > currentCursor ? nextCursor.toString() : cursor;
    return new RemoteArticlePage(items, page.continuation, pageCursor);
  }

  async fetchUnreadIds(baseUrl: string, session: RemoteSession, continuation: string): Promise<RemoteIdPage> {
    return this.client.fetchUnreadIds(baseUrl, session.token, continuation);
  }

  async fetchStarredIds(baseUrl: string, session: RemoteSession, continuation: string): Promise<RemoteIdPage> {
    return this.client.fetchStarredIds(baseUrl, session.token, continuation);
  }

  async subscribeFeed(baseUrl: string, session: RemoteSession, feedUrl: string): Promise<void> {
    if (feedUrl.trim().length === 0) {
      throw new RemoteError(RemoteErrorCode.EMPTY, 'empty feed url');
    }
    try {
      const writeToken: string = await this.client.fetchWriteToken(baseUrl, session.token);
      await this.client.subscribe(baseUrl, session.token, writeToken, feedUrl.trim());
    } catch (err) {
      // 订阅期间 404 更可能是「这个地址不是可用订阅源」，而不是整个 API 未开启。
      if (err instanceof RemoteError && err.code === RemoteErrorCode.API_DISABLED) {
        throw new RemoteError(RemoteErrorCode.SUBSCRIPTION_FAILED, 'feed rejected by server');
      }
      if (err instanceof RemoteError) {
        throw err;
      }
      throw new RemoteError(RemoteErrorCode.SUBSCRIPTION_FAILED, 'subscribe failed');
    }
  }

  async pushStateChanges(baseUrl: string, session: RemoteSession,
    changes: RemoteStateChange[]): Promise<RemotePushResult> {
    const ops: EditTagOp[] = [];
    for (let i = 0; i < changes.length; i += 1) {
      const op: EditTagOp | undefined = toEditTagOp(changes[i]);
      if (op !== undefined) {
        ops.push(op);
      }
    }
    const appliedSet: Set<string> = new Set();
    const failedSet: Set<string> = new Set();
    const errors: string[] = [];
    if (ops.length === 0) {
      return new RemotePushResult([], [], errors);
    }
    let writeToken: string = '';
    for (let offset = 0; offset < ops.length; offset += RemoteSyncConstants.WRITE_BATCH) {
      const batch: EditTagOp[] = ops.slice(offset, offset + RemoteSyncConstants.WRITE_BATCH);
      if (writeToken.length === 0) {
        writeToken = await this.client.fetchWriteToken(baseUrl, session.token);
      }
      // 同一组增删标签的条目合并成一次 edit-tag。
      const groupKeys: string[] = [];
      const groups: Map<string, EditTagOp[]> = new Map<string, EditTagOp[]>();
      for (let i = 0; i < batch.length; i += 1) {
        const op: EditTagOp = batch[i];
        const key: string = op.addTags.join(',') + '|' + op.removeTags.join(',');
        let bucket: EditTagOp[] | undefined = groups.get(key);
        if (bucket === undefined) {
          bucket = [];
          groups.set(key, bucket);
          groupKeys.push(key);
        }
        bucket.push(op);
      }
      for (let g = 0; g < groupKeys.length; g += 1) {
        const group: EditTagOp[] | undefined = groups.get(groupKeys[g]);
        if (group === undefined || group.length === 0) {
          continue;
        }
        const remoteIds: string[] = [];
        for (let i = 0; i < group.length; i += 1) {
          remoteIds.push(group[i].remoteId);
        }
        try {
          await this.client.editTagMany(baseUrl, session.token, writeToken,
            remoteIds, group[0].addTags, group[0].removeTags);
          for (let i = 0; i < remoteIds.length; i += 1) {
            appliedSet.add(remoteIds[i]);
          }
        } catch (err) {
          const code: RemoteErrorCode = codeOf(err);
          if (code === RemoteErrorCode.AUTH) {
            for (let i = 0; i < remoteIds.length; i += 1) {
              failedSet.add(remoteIds[i]);
            }
            errors.push(code.toString());
            throw new RemoteError(code, 'auth expired during push');
          }
          // 部分实现不支持一次带多个 i：多 id 失败时退回逐条。
          if (group.length > 1) {
            for (let i = 0; i < group.length; i += 1) {
              const single: EditTagOp = group[i];
              try {
                await this.client.editTag(baseUrl, session.token, writeToken,
                  single.remoteId, single.addTags, single.removeTags);
                appliedSet.add(single.remoteId);
              } catch (singleErr) {
                const singleCode: RemoteErrorCode = codeOf(singleErr);
                failedSet.add(single.remoteId);
                errors.push(singleCode.toString());
                if (singleCode === RemoteErrorCode.AUTH) {
                  throw new RemoteError(singleCode, 'auth expired during push');
                }
              }
            }
          } else {
            failedSet.add(group[0].remoteId);
            errors.push(code.toString());
          }
        }
      }
    }
    const applied: string[] = [];
    const failed: string[] = [];
    appliedSet.forEach((id: string) => {
      applied.push(id);
    });
    failedSet.forEach((id: string) => {
      failed.push(id);
    });
    return new RemotePushResult(applied, failed, errors);
  }

  betterCursor(current: string, candidate: string): string {
    if (candidate.length === 0) {
      return current;
    }
    const value: number = Number.parseInt(candidate, 10);
    if (Number.isNaN(value) || value <= 0) {
      return current;
    }
    if (current.length === 0) {
      return candidate;
    }
    const base: number = Number.parseInt(current, 10);
    if (Number.isNaN(base) || value > base) {
      return candidate;
    }
    return current;
  }
}

export const gReaderBackend: GReaderBackend = new GReaderBackend();
