/*
 * MockSyncBackend.ets — 本机「远端」，用于演示与单测。
 *
 * 数据存在应用偏好库里（不上传、不发网络请求），语义对齐真实后端：
 *   - 每条记录带自增 rev，作为增量游标（pull 返回 rev > cursor 的记录）；
 *   - push 幂等：同 key 覆盖并分配新 rev；
 *   - reset 清空记录与 rev 计数。
 *
 * 这样设置页能完整走通「本地 → 远端 → 合并 → 回写」链路，
 * 接真实服务端时只需换一个 SyncBackend 实现。
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesConstants } from '../../common/constants/PreferencesConstants';
import { SyncPullPage, SyncPushResult, SyncRecord } from '../../model/Sync';
import { SyncBackend, SyncBackendError, SyncErrorKind } from './SyncBackend';

const DOMAIN: number = 0x0000;
const TAG: string = 'MockSyncBackend';

/** 落盘的远端记录（rev 只在 Mock 内部用）。 */
interface StoredSyncRecord {
  key: string;
  kind: string;
  updatedAt: number;
  deleted: boolean;
  payload: string;
  origin: string;
  rev: number;
}

/** ArkTS 不支持索引签名，用带数组字段的接口承载列表。 */
interface StoredRecordList {
  items: StoredSyncRecord[];
}

/** 落盘外壳：记录 + 下一个 rev（一起写，避免游标回退）。 */
interface MockSyncDb {
  seq: number;
  records: StoredRecordList;
}

function toRecord(item: StoredSyncRecord): SyncRecord {
  const payload: string = typeof item.payload === 'string' ? item.payload : '';
  const origin: string = typeof item.origin === 'string' ? item.origin : '';
  return new SyncRecord(item.key, item.kind, item.updatedAt, item.deleted, payload, origin);
}

export class MockSyncBackend implements SyncBackend {
  readonly name: string = 'Mock';
  private readonly context: common.Context;
  private store: preferences.Preferences | undefined = undefined;

  constructor(context: common.Context) {
    this.context = context;
  }

  private async open(): Promise<preferences.Preferences> {
    const opened: preferences.Preferences | undefined = this.store;
    if (opened !== undefined) {
      return opened;
    }
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(this.context, PreferencesConstants.STORE_NAME);
      this.store = store;
      return store;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'open preferences failed: %{public}d', error.code);
      throw new SyncBackendError(SyncErrorKind.UNKNOWN, 'preferences unavailable');
    }
  }

  private loadDb(store: preferences.Preferences): MockSyncDb {
    const raw: preferences.ValueType = store.getSync(PreferencesConstants.KEY_CLOUD_SYNC_MOCK_DB, '');
    const text: string = typeof raw === 'string' ? raw : '';
    if (text.length === 0) {
      const empty: StoredRecordList = { items: [] };
      return { seq: 0, records: empty };
    }
    try {
      const db: MockSyncDb = JSON.parse(text) as MockSyncDb;
      const items: StoredSyncRecord[] = db.records !== undefined && db.records.items !== undefined
        ? db.records.items : [];
      const seq: number = typeof db.seq === 'number' && Number.isFinite(db.seq) && db.seq > 0 ? db.seq : 0;
      const list: StoredRecordList = { items: items };
      return { seq: seq, records: list };
    } catch (err) {
      // 坏数据按空库处理：远端内容可重建，不能因此阻塞同步。
      hilog.warn(DOMAIN, TAG, 'mock db corrupted, resetting');
      const empty: StoredRecordList = { items: [] };
      return { seq: 0, records: empty };
    }
  }

  private async saveDb(store: preferences.Preferences, db: MockSyncDb): Promise<void> {
    try {
      store.putSync(PreferencesConstants.KEY_CLOUD_SYNC_MOCK_DB, JSON.stringify(db));
      await store.flush();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'persist mock db failed: %{public}d', error.code);
      throw new SyncBackendError(SyncErrorKind.UNKNOWN, 'preferences write failed');
    }
  }

  async pull(cursor: string, limit: number): Promise<SyncPullPage> {
    const store: preferences.Preferences = await this.open();
    const db: MockSyncDb = this.loadDb(store);
    const parsed: number = Number(cursor);
    const from: number = Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
    const items: StoredSyncRecord[] = db.records.items.slice();
    items.sort((left: StoredSyncRecord, right: StoredSyncRecord): number => left.rev - right.rev);
    const page: SyncRecord[] = [];
    let next: string = '';
    const cap: number = limit > 0 ? limit : 100;
    for (let i = 0; i < items.length && page.length < cap; i += 1) {
      const item: StoredSyncRecord = items[i];
      if (item.rev <= from) {
        continue;
      }
      page.push(toRecord(item));
      next = item.rev.toString();
    }
    return new SyncPullPage(page, next);
  }

  async push(records: SyncRecord[]): Promise<SyncPushResult> {
    const store: preferences.Preferences = await this.open();
    const db: MockSyncDb = this.loadDb(store);
    const accepted: string[] = [];
    const items: StoredSyncRecord[] = db.records.items.slice();
    let seq: number = db.seq;
    for (let i = 0; i < records.length; i += 1) {
      const record: SyncRecord = records[i];
      if (record.key.length === 0) {
        continue;
      }
      seq += 1;
      const stored: StoredSyncRecord = {
        key: record.key,
        kind: record.kind,
        updatedAt: record.updatedAt,
        deleted: record.deleted,
        payload: record.payload,
        origin: record.origin,
        rev: seq
      };
      let replaced: boolean = false;
      for (let j = 0; j < items.length; j += 1) {
        if (items[j].key === record.key) {
          items[j] = stored;
          replaced = true;
          break;
        }
      }
      if (!replaced) {
        items.push(stored);
      }
      accepted.push(record.key);
    }
    const nextList: StoredRecordList = { items: items };
    const nextDb: MockSyncDb = { seq: seq, records: nextList };
    await this.saveDb(store, nextDb);
    return new SyncPushResult(accepted, [], []);
  }

  betterCursor(current: string, candidate: string): string {
    const left: number = Number(current);
    const right: number = Number(candidate);
    const leftValue: number = Number.isFinite(left) ? left : 0;
    const rightValue: number = Number.isFinite(right) ? right : 0;
    return rightValue > leftValue ? candidate : current;
  }

  async reset(): Promise<void> {
    const store: preferences.Preferences = await this.open();
    const empty: StoredRecordList = { items: [] };
    const db: MockSyncDb = { seq: 0, records: empty };
    await this.saveDb(store, db);
  }
}
