/*
 * CloudRelayBackend.ets — 以「华为云空间里的同步表」为远端的同步后端。
 *
 * 与 Mock 后端语义一致：pull 按 updatedAt 游标增量取行，push 整行覆盖。
 * 真正的跨设备传输由系统端云同步完成（CloudStore 里登记的分布式表），
 * 因此这里不发起任何网络请求，也不认识华为账号 / token。
 */

import { SyncPullPage, SyncPushResult, SyncRecord } from '../../model/Sync';
import { SyncBackend, SyncBackendError, SyncErrorKind } from './SyncBackend';
import { CloudStore } from './CloudStore';

/** 游标是毫秒时间戳的十进制字符串；非法值按 0（从头开始）。 */
export function numericCursor(cursor: string): number {
  const value: number = Number(cursor);
  return Number.isFinite(value) && value > 0 ? value : 0;
}

export class CloudRelayBackend implements SyncBackend {
  readonly name: string = 'Cloud';
  private readonly store: CloudStore;

  constructor(store: CloudStore) {
    this.store = store;
  }

  async pull(cursor: string, limit: number): Promise<SyncPullPage> {
    const from: number = numericCursor(cursor);
    const cap: number = limit > 0 ? limit : 100;
    const all: SyncRecord[] = await this.store.listAll();
    const page: SyncRecord[] = [];
    let next: number = from;
    for (let i = 0; i < all.length; i += 1) {
      const row: SyncRecord = all[i];
      if (row.updatedAt <= from) {
        continue;
      }
      if (page.length >= cap) {
        break;
      }
      page.push(row);
      if (row.updatedAt > next) {
        next = row.updatedAt;
      }
    }
    return new SyncPullPage(page, next > from ? next.toString() : cursor);
  }

  async push(records: SyncRecord[]): Promise<SyncPushResult> {
    const accepted: string[] = [];
    const rejected: string[] = [];
    for (let i = 0; i < records.length; i += 1) {
      const record: SyncRecord = records[i];
      if (record.key.length === 0) {
        rejected.push(record.key);
        continue;
      }
      if (this.store.upsert(record)) {
        accepted.push(record.key);
      } else {
        rejected.push(record.key);
      }
    }
    if (accepted.length === 0 && records.length > 0) {
      throw new SyncBackendError(SyncErrorKind.API, 'cloud write failed');
    }
    return new SyncPushResult(accepted, rejected, []);
  }

  betterCursor(current: string, candidate: string): string {
    return numericCursor(candidate) > numericCursor(current) ? candidate : current;
  }

  async reset(): Promise<void> {
    this.store.clear();
  }
}
