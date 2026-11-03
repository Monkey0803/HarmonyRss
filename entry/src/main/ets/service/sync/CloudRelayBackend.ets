/*
 * CloudRelayBackend.ets — 以「华为云空间里的同步表」为远端的同步后端。
 *
 * 与 Mock 后端语义一致：pull 按时间戳和主键组成的游标增量取行，push 整行覆盖。
 * 真正的跨设备传输由系统端云同步完成（CloudStore 里登记的分布式表），
 * 因此这里不发起任何网络请求，也不认识华为账号 / token。
 */

import { SyncPullPage, SyncPushResult, SyncRecord } from '../../model/Sync';
import { SyncBackend, SyncBackendError, SyncErrorKind } from './SyncBackend';
import { CloudStore } from './CloudStore';

/** 旧版时间戳游标的解析保留给兼容测试；新游标由 CloudCursor 解析。 */
export function numericCursor(cursor: string): number {
  const value: number = Number(cursor);
  return Number.isFinite(value) && value > 0 ? value : 0;
}

/** v2 游标不依赖字符转义：长度字段后面的全部内容都是 recordKey。 */
export class CloudCursor {
  readonly updatedAt: number;
  readonly recordKey: string;
  readonly versioned: boolean;

  constructor(updatedAt: number, recordKey: string, versioned: boolean) {
    this.updatedAt = updatedAt;
    this.recordKey = recordKey;
    this.versioned = versioned;
  }
}

export function encodeCloudCursor(updatedAt: number, recordKey: string): string {
  return 'v2:' + updatedAt + ':' + recordKey.length + ':' + recordKey;
}

/** 旧数字游标和脏值从头读取；首个非空页会升级为 v2，以补齐旧版可能漏掉的记录。 */
export function parseCloudCursor(raw: string): CloudCursor {
  if (!raw.startsWith('v2:')) {
    return new CloudCursor(0, '', false);
  }
  const timeEnd: number = raw.indexOf(':', 3);
  const lengthEnd: number = timeEnd < 0 ? -1 : raw.indexOf(':', timeEnd + 1);
  if (timeEnd < 0 || lengthEnd < 0) {
    return new CloudCursor(0, '', false);
  }
  const timeText: string = raw.substring(3, timeEnd);
  const lengthText: string = raw.substring(timeEnd + 1, lengthEnd);
  const recordKey: string = raw.substring(lengthEnd + 1);
  const updatedAt: number = Number(timeText);
  const keyLength: number = Number(lengthText);
  if (!/^\d+$/.test(timeText) || !/^\d+$/.test(lengthText) ||
    !Number.isSafeInteger(updatedAt) || updatedAt <= 0 ||
    !Number.isSafeInteger(keyLength) || keyLength !== recordKey.length) {
    return new CloudCursor(0, '', false);
  }
  return new CloudCursor(updatedAt, recordKey, true);
}

/** 与 SQLite 默认 BINARY 排序一致地比较 Unicode 码点。 */
function compareRecordKeys(left: string, right: string): number {
  let leftIndex: number = 0;
  let rightIndex: number = 0;
  while (leftIndex < left.length && rightIndex < right.length) {
    const leftValue: number | undefined = left.codePointAt(leftIndex);
    const rightValue: number | undefined = right.codePointAt(rightIndex);
    const leftPoint: number = leftValue === undefined ? 0 : leftValue;
    const rightPoint: number = rightValue === undefined ? 0 : rightValue;
    if (leftPoint !== rightPoint) {
      return leftPoint < rightPoint ? -1 : 1;
    }
    leftIndex += leftPoint > 0xFFFF ? 2 : 1;
    rightIndex += rightPoint > 0xFFFF ? 2 : 1;
  }
  return leftIndex === left.length ? (rightIndex === right.length ? 0 : -1) : 1;
}

export class CloudRelayBackend implements SyncBackend {
  readonly name: string = 'Cloud';
  private readonly store: CloudStore;

  constructor(store: CloudStore) {
    this.store = store;
  }

  async pull(cursor: string, limit: number): Promise<SyncPullPage> {
    const from: CloudCursor = parseCloudCursor(cursor);
    const cap: number = limit > 0 ? limit : 100;
    const page: SyncRecord[] = await this.store.listSince(from.updatedAt, from.recordKey, cap);
    const last: SyncRecord | undefined = page.length > 0 ? page[page.length - 1] : undefined;
    return new SyncPullPage(page,
      last === undefined ? cursor : encodeCloudCursor(last.updatedAt, last.key));
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
    const left: CloudCursor = parseCloudCursor(current);
    const right: CloudCursor = parseCloudCursor(candidate);
    if (right.versioned && !left.versioned) {
      return candidate;
    }
    if (!right.versioned && left.versioned) {
      return current;
    }
    if (!right.versioned && !left.versioned) {
      return numericCursor(candidate) > numericCursor(current) ? candidate : current;
    }
    if (right.updatedAt > left.updatedAt ||
      (right.updatedAt === left.updatedAt && compareRecordKeys(right.recordKey, left.recordKey) > 0)) {
      return candidate;
    }
    return current;
  }

  async reset(): Promise<void> {
    this.store.clear();
  }
}
