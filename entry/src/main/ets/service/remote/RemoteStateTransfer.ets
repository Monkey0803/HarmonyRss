/* 远端文章已读与收藏状态的批量上传、拉取和组内回写。 */
import {
  ArticleState, OutboxItem, RemoteAccount, RemoteError, RemoteErrorCode,
  RemoteIdPage, RemoteMapping, SyncResult
} from '../../model/Remote';
import { RemoteSyncConstants } from '../../common/constants/RssConstants';
import { articleRepository } from '../ArticleServices';
import { dedupeService } from '../DedupeService';
import { remoteAccountStore } from '../RemoteAccountStore';
import { RemoteBackend, RemotePushResult, RemoteSession, RemoteStateChange } from './RemoteBackend';
import { decideState } from './RemoteSyncPlan';

export class RemoteStateTransfer {
  private codeOfObject(err: Object): RemoteErrorCode {
    return err instanceof RemoteError ? err.code : RemoteErrorCode.SERVER;
  }

  /** 回写本地已读 / 收藏：统一的远端变更交给后端批量处理。 */
  async pushStates(account: RemoteAccount, backend: RemoteBackend,
    session: RemoteSession, result: SyncResult): Promise<void> {
    const pending: OutboxItem[] =
      await remoteAccountStore.pendingItems(RemoteSyncConstants.MAX_ARTICLES_PER_SYNC);
    if (pending.length === 0) {
      return;
    }
    const mappings: RemoteMapping[] = await remoteAccountStore.allMappings();
    const remoteIds: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < mappings.length; i += 1) {
      remoteIds.set(mappings[i].articleId, mappings[i].remoteId);
    }
    const changes: RemoteStateChange[] = [];
    const localIds: string[] = [];
    for (let i = 0; i < pending.length; i += 1) {
      const item: OutboxItem = pending[i];
      const remoteId: string | undefined = remoteIds.get(item.articleId);
      if (remoteId === undefined || (!item.setRead && !item.setStarred)) {
        continue;
      }
      changes.push(new RemoteStateChange(remoteId,
        item.setRead ? item.readValue : undefined,
        item.setStarred ? item.starredValue : undefined));
      localIds.push(item.articleId);
    }
    if (changes.length === 0) {
      // 没有任何可回写的映射 / 变更：直接清掉，避免队列永久积压。
      const orphans: string[] = [];
      for (let i = 0; i < pending.length; i += 1) {
        orphans.push(pending[i].articleId);
      }
      await remoteAccountStore.ackItems(orphans);
      return;
    }
    const pushResult: RemotePushResult =
      await backend.pushStateChanges(account.baseUrl, session, changes);
    for (let i = 0; i < pushResult.errors.length; i += 1) {
      result.errors.push(pushResult.errors[i]);
    }
    const applied: Set<string> = new Set(pushResult.applied);
    const failed: Set<string> = new Set(pushResult.failed);
    const failedText: string = pushResult.errors.length > 0
      ? pushResult.errors[0]
      : RemoteErrorCode.SERVER.toString();
    const acked: string[] = [];
    const attempted: Set<string> = new Set<string>();
    for (let i = 0; i < changes.length; i += 1) {
      const remoteId: string = changes[i].remoteId;
      const localId: string = localIds[i];
      attempted.add(localId);
      if (applied.has(remoteId) && !failed.has(remoteId)) {
        acked.push(localId);
        result.statesPushed += 1;
      } else {
        await remoteAccountStore.failItem(localId, failedText);
      }
    }
    if (acked.length > 0) {
      await remoteAccountStore.ackItems(acked);
    }
    // 没有远端映射 / 没有任何变更的条目：清掉，避免永久重试。
    if (attempted.size < pending.length) {
      const orphans: string[] = [];
      for (let i = 0; i < pending.length; i += 1) {
        if (!attempted.has(pending[i].articleId) && !remoteIds.has(pending[i].articleId)) {
          orphans.push(pending[i].articleId);
        }
      }
      await remoteAccountStore.ackItems(orphans);
    }
  }

  /** 拉回远端已读 / 收藏：只更新状态列，不覆盖正文 / 进度 / 标签。 */
  async pullStates(account: RemoteAccount, backend: RemoteBackend,
    session: RemoteSession, result: SyncResult): Promise<void> {
    let unreadOk: boolean = true;
    let starredOk: boolean = true;
    let unread: Set<string> = new Set<string>();
    let starred: Set<string> = new Set<string>();
    try {
      unread = await this.collectIds((continuation: string): Promise<RemoteIdPage> => {
        return backend.fetchUnreadIds(account.baseUrl, session, continuation);
      });
    } catch (err) {
      const code: RemoteErrorCode = this.codeOfObject(err);
      if (code === RemoteErrorCode.AUTH) {
        throw new RemoteError(code, 'auth expired during pull');
      }
      unreadOk = false;
      unread = new Set<string>();
      result.errors.push(code.toString());
    }
    try {
      starred = await this.collectIds((continuation: string): Promise<RemoteIdPage> => {
        return backend.fetchStarredIds(account.baseUrl, session, continuation);
      });
    } catch (err) {
      const code: RemoteErrorCode = this.codeOfObject(err);
      if (code === RemoteErrorCode.AUTH) {
        throw new RemoteError(code, 'auth expired during pull');
      }
      starredOk = false;
      starred = new Set<string>();
      result.errors.push(code.toString());
    }
    const mappings: RemoteMapping[] = await remoteAccountStore.allMappings();
    if (mappings.length === 0) {
      return;
    }
    const pendingIds: Set<string> = new Set<string>();
    const pending: OutboxItem[] =
      await remoteAccountStore.pendingItems(RemoteSyncConstants.MAX_ARTICLES_PER_SYNC);
    for (let i = 0; i < pending.length; i += 1) {
      pendingIds.add(pending[i].articleId);
    }
    const ids: string[] = [];
    for (let i = 0; i < mappings.length; i += 1) {
      ids.push(mappings[i].articleId);
    }
    const states: ArticleState[] = await articleRepository.loadStates(ids);
    const stateById: Map<string, ArticleState> = new Map<string, ArticleState>();
    for (let i = 0; i < states.length; i += 1) {
      stateById.set(states[i].articleId, states[i]);
    }
    let pulled: number = 0;
    // 决策先全部算完再统一落库：回写是「整组」语义，逐条写会互相覆盖组内状态，
    // 也避免一次同步里做 O(映射数) 次 UPDATE。
    const readTargets: string[] = [];
    const unreadTargets: string[] = [];
    const starredTargets: string[] = [];
    const unstarredTargets: string[] = [];
    for (let i = 0; i < mappings.length; i += 1) {
      const mapping: RemoteMapping = mappings[i];
      const local: ArticleState | undefined = stateById.get(mapping.articleId);
      if (local === undefined) {
        continue;
      }
      const remoteRead: boolean = unreadOk ? !unread.has(mapping.remoteId) : local.read;
      const remoteStarred: boolean = starredOk ? starred.has(mapping.remoteId) : local.starred;
      const decision = decideState(local.read, local.starred, remoteRead, remoteStarred,
        pendingIds.has(mapping.articleId));
      if (decision.read !== local.read) {
        if (decision.read) {
          readTargets.push(mapping.articleId);
        } else {
          unreadTargets.push(mapping.articleId);
        }
        pulled += 1;
      }
      if (decision.starred !== local.starred) {
        if (decision.starred) {
          starredTargets.push(mapping.articleId);
        } else {
          unstarredTargets.push(mapping.articleId);
        }
        pulled += 1;
      }
    }
    // 回写作用到整组：先解析主条 / 重复项再批量落库，保证组内状态一致（FR-006）。
    if (readTargets.length > 0) {
      await dedupeService.applyRead(readTargets, true);
    }
    if (unreadTargets.length > 0) {
      await dedupeService.applyRead(unreadTargets, false);
    }
    if (starredTargets.length > 0) {
      await dedupeService.applyStarred(starredTargets, true);
    }
    if (unstarredTargets.length > 0) {
      await dedupeService.applyStarred(unstarredTargets, false);
    }
    result.statesPulled = pulled;
  }

  /** 分页收集 id（最多 MAX_ID_PAGES 页）。 */
  private async collectIds(fetcher: (continuation: string) => Promise<RemoteIdPage>): Promise<Set<string>> {
    const ids: Set<string> = new Set<string>();
    let continuation: string = '';
    let pages: number = 0;
    while (pages < RemoteSyncConstants.MAX_ID_PAGES) {
      const page: RemoteIdPage = await fetcher(continuation);
      pages += 1;
      for (let i = 0; i < page.ids.length; i += 1) {
        ids.add(page.ids[i]);
      }
      if (page.continuation.length === 0) {
        break;
      }
      continuation = page.continuation;
    }
    return ids;
  }

}
