/*
 * SyncEngine.test.ets — 同步编排（推送 / 拉取 / 合并 / 回推 / 游标）单测。
 *
 * 用内存版 Backend + Store 替换真实后端与 RDB，验证语义而不是存储细节：
 *   - 本地脏记录推送后标干净并推进游标；
 *   - 远端新增记录拉下后落库为干净记录；
 *   - 两端同时改动时字段级合并（A 端已读 + B 端星标都保留），合并不一致时回推；
 *   - 重复同步幂等；
 *   - 后端推送失败时不丢脏标记（下次重试）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ArticleStatePayload,
  SyncField,
  SyncKinds,
  SyncPullPage,
  SyncPushResult,
  SyncRecord,
  SyncSummary,
  encodeArticleStatePayload
} from '../../../main/ets/model/Sync';
import { SyncBackend, SyncBackendError, SyncErrorKind } from '../../../main/ets/service/sync/SyncBackend';
import { SyncEngine } from '../../../main/ets/service/sync/SyncEngine';
import { SyncRecordStore } from '../../../main/ets/service/sync/SyncStore';

/** 内存版远端：rev 自增，push 幂等覆盖。 */
class MemoryBackend implements SyncBackend {
  readonly name: string = 'memory';
  private records: Map<string, SyncRecord> = new Map<string, SyncRecord>();
  private revs: Map<string, number> = new Map<string, number>();
  private seq: number = 0;
  failPush: boolean = false;

  pull(cursor: string, limit: number): Promise<SyncPullPage> {
    const from: number = cursor.length > 0 ? Number(cursor) : 0;
    const keys: string[] = [];
    this.revs.forEach((rev: number, key: string) => {
      if (rev > from) {
        keys.push(key);
      }
    });
    keys.sort((left: string, right: string): number => this.revOf(left) - this.revOf(right));
    const page: SyncRecord[] = [];
    let next: string = '';
    for (let i = 0; i < keys.length && page.length < limit; i += 1) {
      const record: SyncRecord | undefined = this.records.get(keys[i]);
      if (record !== undefined) {
        page.push(record);
        next = this.revOf(keys[i]).toString();
      }
    }
    return Promise.resolve(new SyncPullPage(page, next));
  }

  push(records: SyncRecord[]): Promise<SyncPushResult> {
    if (this.failPush) {
      return Promise.reject(new SyncBackendError(SyncErrorKind.NETWORK, 'offline'));
    }
    const accepted: string[] = [];
    for (let i = 0; i < records.length; i += 1) {
      const record: SyncRecord = records[i];
      this.records.set(record.key, record);
      this.seq += 1;
      this.revs.set(record.key, this.seq);
      accepted.push(record.key);
    }
    return Promise.resolve(new SyncPushResult(accepted, [], []));
  }

  betterCursor(current: string, candidate: string): string {
    const left: number = Number.isFinite(Number(current)) ? Number(current) : 0;
    const right: number = Number.isFinite(Number(candidate)) ? Number(candidate) : 0;
    return right > left ? candidate : current;
  }

  reset(): Promise<void> {
    this.records.clear();
    this.revs.clear();
    this.seq = 0;
    return Promise.resolve();
  }

  revOf(key: string): number {
    const rev: number | undefined = this.revs.get(key);
    return rev === undefined ? 0 : rev;
  }

  recordOf(key: string): SyncRecord | undefined {
    return this.records.get(key);
  }
}

/** 内存版本地同步表。 */
class MemoryStore implements SyncRecordStore {
  private records: Map<string, SyncRecord> = new Map<string, SyncRecord>();
  private dirty: Set<string> = new Set<string>();
  private cursor: string = '';

  listByKind(kind: string): Promise<SyncRecord[]> {
    const result: SyncRecord[] = [];
    this.records.forEach((record: SyncRecord) => {
      if (record.kind === kind) {
        result.push(record);
      }
    });
    return Promise.resolve(result);
  }

  find(key: string): Promise<SyncRecord | undefined> {
    return Promise.resolve(this.records.get(key));
  }

  listDirty(limit: number): Promise<SyncRecord[]> {
    const result: SyncRecord[] = [];
    this.records.forEach((record: SyncRecord, key: string) => {
      if (this.dirty.has(key)) {
        result.push(record);
      }
    });
    return Promise.resolve(result.slice(0, limit));
  }

  upsert(record: SyncRecord, isDirty: boolean, rev: string = ''): void {
    this.records.set(record.key, record);
    if (isDirty) {
      this.dirty.add(record.key);
    } else {
      this.dirty.delete(record.key);
    }
  }

  markClean(keys: string[]): void {
    for (let i = 0; i < keys.length; i += 1) {
      this.dirty.delete(keys[i]);
    }
  }

  pendingCount(): Promise<number> {
    return Promise.resolve(this.dirty.size);
  }

  recordCount(): Promise<number> {
    return Promise.resolve(this.records.size);
  }

  getCursor(): Promise<string> {
    return Promise.resolve(this.cursor);
  }

  setCursor(cursor: string): void {
    this.cursor = cursor;
  }

  clearAll(): void {
    this.records.clear();
    this.dirty.clear();
    this.cursor = '';
  }

  isDirty(key: string): boolean {
    return this.dirty.has(key);
  }

  seed(record: SyncRecord, isDirty: boolean): void {
    this.upsert(record, isDirty);
  }
}

function stateRecord(read: string, starred: string, readAt: number, starredAt: number,
  origin: string): SyncRecord {
  const payload = new ArticleStatePayload(
    new SyncField(read, readAt), new SyncField(starred, starredAt),
    new SyncField('0', 0), new SyncField('0', 0));
  return new SyncRecord('article:1', SyncKinds.ARTICLE_STATE, Math.max(readAt, starredAt),
    false, encodeArticleStatePayload(payload), origin);
}

function stateOf(record: SyncRecord | undefined): ArticleStatePayload {
  if (record === undefined) {
    return new ArticleStatePayload(new SyncField('0', 0), new SyncField('0', 0),
      new SyncField('0', 0), new SyncField('0', 0));
  }
  const payload: ArticleStatePayload = JSON.parse(record.payload) as ArticleStatePayload;
  return payload;
}

export default function syncEngineTest() {
  describe('SyncEngine', () => {
    it('pushes_dirty_records_and_clears_flags', 0, async () => {
      const backend: MemoryBackend = new MemoryBackend();
      const store: MemoryStore = new MemoryStore();
      store.seed(stateRecord('1', '0', 100, 0, 'node-a'), true);
      const engine: SyncEngine = new SyncEngine(backend, store, 'node-a');
      const summary: SyncSummary = await engine.run();
      expect(summary.error).assertEqual('');
      expect(summary.pushed).assertEqual(1);
      expect(store.isDirty('article:1')).assertFalse();
      expect(backend.recordOf('article:1') !== undefined).assertTrue();
    });

    it('pulls_remote_only_records_as_clean', 0, async () => {
      const backend: MemoryBackend = new MemoryBackend();
      const store: MemoryStore = new MemoryStore();
      await backend.push([stateRecord('0', '1', 0, 200, 'node-b')]);
      const engine: SyncEngine = new SyncEngine(backend, store, 'node-a');
      const summary: SyncSummary = await engine.run();
      expect(summary.pulled).assertEqual(1);
      expect(store.isDirty('article:1')).assertFalse();
      expect(stateOf(await store.find('article:1')).starred.value).assertEqual('1');
    });

    it('merges_conflicting_fields_and_pushes_result_back', 0, async () => {
      const backend: MemoryBackend = new MemoryBackend();
      const store: MemoryStore = new MemoryStore();
      // 远端：B 端在 300 打了星标（游标之后的新记录）。
      await backend.push([stateRecord('0', '1', 0, 300, 'node-b')]);
      // 本地：A 端在 200 标了已读（待推送）。两边改动都要保留。
      store.seed(stateRecord('1', '0', 200, 0, 'node-a'), true);
      const engine: SyncEngine = new SyncEngine(backend, store, 'node-a');
      const summary: SyncSummary = await engine.run();
      expect(summary.error).assertEqual('');
      expect(summary.conflicts >= 1).assertTrue();
      const merged: ArticleStatePayload = stateOf(backend.recordOf('article:1'));
      expect(merged.read.value).assertEqual('1');
      expect(merged.starred.value).assertEqual('1');
      expect(store.isDirty('article:1')).assertFalse();
    });

    it('converges_when_both_sides_edited_offline', 0, async () => {
      const backend: MemoryBackend = new MemoryBackend();
      // 两端离线各改一个字段：A 标已读、B 打星标，都没有先拉到对方的状态。
      const storeA: MemoryStore = new MemoryStore();
      const storeB: MemoryStore = new MemoryStore();
      storeA.seed(stateRecord('1', '0', 200, 0, 'node-a'), true);
      storeB.seed(stateRecord('0', '1', 0, 300, 'node-b'), true);
      const engineA: SyncEngine = new SyncEngine(backend, storeA, 'node-a');
      const engineB: SyncEngine = new SyncEngine(backend, storeB, 'node-b');
      await engineA.run();
      // 先拉后推：B 这一轮就能拉到 A 的记录、字段级合并并一次回写，不必再来回。
      await engineB.run();
      const afterB: ArticleStatePayload = stateOf(backend.recordOf('article:1'));
      expect(afterB.read.value).assertEqual('1');
      expect(afterB.starred.value).assertEqual('1');
      expect(await storeB.pendingCount()).assertEqual(0);
      // A 下一轮拉回合并结果：两端状态一致。
      await engineA.run();
      const merged: ArticleStatePayload = stateOf(await storeA.find('article:1'));
      expect(merged.read.value).assertEqual('1');
      expect(merged.starred.value).assertEqual('1');
      expect(await storeA.pendingCount()).assertEqual(0);
    });

    it('is_idempotent_across_runs', 0, async () => {
      const backend: MemoryBackend = new MemoryBackend();
      const store: MemoryStore = new MemoryStore();
      await backend.push([stateRecord('0', '1', 0, 300, 'node-b')]);
      store.seed(stateRecord('1', '0', 200, 0, 'node-a'), true);
      const engine: SyncEngine = new SyncEngine(backend, store, 'node-a');
      const firstSummary: SyncSummary = await engine.run();
      const firstRecord: SyncRecord | undefined = backend.recordOf('article:1');
      const first: ArticleStatePayload = stateOf(firstRecord);
      const secondSummary: SyncSummary = await engine.run();
      const secondRecord: SyncRecord | undefined = backend.recordOf('article:1');
      const second: ArticleStatePayload = stateOf(secondRecord);
      expect(firstSummary.error).assertEqual('');
      expect(secondSummary.error).assertEqual('');
      // 第二轮不应再产生新的合并结果：读 / 星标 / 时间戳都保持不变。
      expect(second.read.value).assertEqual(first.read.value);
      expect(second.starred.value).assertEqual(first.starred.value);
      expect(secondRecord !== undefined && firstRecord !== undefined &&
        secondRecord.updatedAt === firstRecord.updatedAt).assertTrue();
      expect(await store.pendingCount()).assertEqual(0);
    });

    it('keeps_dirty_when_push_fails', 0, async () => {
      const backend: MemoryBackend = new MemoryBackend();
      const store: MemoryStore = new MemoryStore();
      store.seed(stateRecord('1', '0', 100, 0, 'node-a'), true);
      backend.failPush = true;
      const engine: SyncEngine = new SyncEngine(backend, store, 'node-a');
      const summary: SyncSummary = await engine.run();
      expect(summary.error.length > 0).assertTrue();
      expect(store.isDirty('article:1')).assertTrue();
    });
  });
}
