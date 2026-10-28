/*
 * SyncEngine.ets — 同步编排：拉取 → 合并 → 推送 → 推进游标。
 *
 * 只依赖 `SyncBackend` 与 `SyncStore`，不认识订阅源 / 文章这些领域对象：
 * 领域数据的采集与应用在 SyncCollector，换真实后端时本文件不用改。
 *
 * 为什么先拉后推：后端（含 Mock）按「整条记录覆盖」落库，若先推自己那份副本，
 * 就会把对端改过的其它字段直接盖掉，字段级合并失去意义。先拉能拿到远端字段值，
 * 合并后标脏，再由同一轮推送把完整状态回写。
 *
 * 失败语义：不抛异常，统一收敛成 `SyncSummary.error`（分类文案），
 * 本地数据与游标保持上一次可用状态，下次同步继续。
 */

import { SyncPullPage, SyncPushResult, SyncRecord, SyncSummary, isSameRecord, mergeRecord } from '../../model/Sync';
import { SyncBackend, SyncBackendError } from './SyncBackend';
import { SyncLimits, SyncRecordStore } from './SyncStore';

/** 推送一轮的结果。 */
class PushRound {
  readonly pushed: number;
  readonly accepted: string[];
  readonly failed: boolean;

  constructor(pushed: number, accepted: string[], failed: boolean) {
    this.pushed = pushed;
    this.accepted = accepted;
    this.failed = failed;
  }
}

export class SyncEngine {
  private readonly backend: SyncBackend;
  private readonly store: SyncRecordStore;
  private readonly origin: string;

  constructor(backend: SyncBackend, store: SyncRecordStore, origin: string) {
    this.backend = backend;
    this.store = store;
    this.origin = origin;
  }

  /** 推送一批记录（返回可标干净的 key）；后端报错时 failed = true，调用方停止本轮。 */
  private async pushBatch(records: SyncRecord[]): Promise<PushRound> {
    if (records.length === 0) {
      return new PushRound(0, [], false);
    }
    try {
      const result: SyncPushResult = await this.backend.push(records);
      return new PushRound(result.accepted.length, result.accepted, false);
    } catch (err) {
      return new PushRound(0, [], true);
    }
  }

  /** 把待推送记录分批推完（最多几轮，避免持续写入时死循环）。 */
  private async pushPending(): Promise<PushRound> {
    let pushed: number = 0;
    const accepted: string[] = [];
    for (let round = 0; round < 10; round += 1) {
      const dirty: SyncRecord[] = await this.store.listDirty(SyncLimits.PUSH_BATCH);
      if (dirty.length === 0) {
        return new PushRound(pushed, accepted, false);
      }
      const result: PushRound = await this.pushBatch(dirty);
      pushed += result.pushed;
      for (let i = 0; i < result.accepted.length; i += 1) {
        accepted.push(result.accepted[i]);
      }
      if (result.failed) {
        return new PushRound(pushed, accepted, true);
      }
      if (result.accepted.length === 0) {
        return new PushRound(pushed, accepted, false);
      }
      this.store.markClean(result.accepted);
    }
    return new PushRound(pushed, accepted, false);
  }

  /** 完整同步一轮。 */
  async run(): Promise<SyncSummary> {
    let cursor: string = await this.store.getCursor();
    let pulled: number = 0;
    let conflicts: number = 0;
    let failure: string = '';

    for (let page = 0; page < SyncLimits.MAX_PULL_PAGES; page += 1) {
      let pulledPage: SyncPullPage;
      try {
        pulledPage = await this.backend.pull(cursor, SyncLimits.PULL_BATCH);
      } catch (err) {
        const error: SyncBackendError = err as SyncBackendError;
        failure = error.kind !== undefined ? error.kind : 'pull failed';
        break;
      }
      if (pulledPage.records.length === 0) {
        break;
      }
      for (let i = 0; i < pulledPage.records.length; i += 1) {
        const remote: SyncRecord = pulledPage.records[i];
        const local: SyncRecord | undefined = await this.store.find(remote.key);
        if (local === undefined) {
          this.store.upsert(remote, false);
          pulled += 1;
          continue;
        }
        const merged: SyncRecord = mergeRecord(local, remote);
        const differsFromRemote: boolean = !isSameRecord(merged, remote);
        // 合并结果比远端新 / 补上了对端没有的字段：标脏，交给本轮的推送回写。
        this.store.upsert(merged, differsFromRemote);
        pulled += 1;
        if (differsFromRemote) {
          conflicts += 1;
        }
      }
      const nextCursor: string = this.backend.betterCursor(cursor, pulledPage.cursor);
      if (nextCursor === cursor && pulledPage.records.length < SyncLimits.PULL_BATCH) {
        break;
      }
      cursor = nextCursor;
    }

    this.store.setCursor(cursor);
    if (failure.length > 0) {
      return new SyncSummary(0, pulled, conflicts, await this.store.pendingCount(), 0, failure);
    }

    // 本机改动与刚才的合并结果一起推送；失败时保留脏标记，下次重试。
    const pushRound: PushRound = await this.pushPending();
    const pending: number = await this.store.pendingCount();
    if (pushRound.failed) {
      return new SyncSummary(pushRound.pushed, pulled, conflicts, pending, 0, 'push failed');
    }
    return new SyncSummary(pushRound.pushed, pulled, conflicts, pending, Date.now(), '');
  }
}
