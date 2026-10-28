/*
 * SyncBackend.ets — 云同步的传输抽象。
 *
 * 编排层（SyncEngine）只依赖这里的四个方法，不关心是 HTTP、Mock 还是以后的自建服务端：
 *   - pull(cursor, limit)：拉取游标之后的记录（游标语义由 Backend 决定）；
 *   - push(records)：幂等推送，同 key 后写覆盖；
 *   - betterCursor(current, candidate)：比较两个游标哪个更新；
 *   - reset()：清空远端（仅 Mock / 调试用）。
 *
 * 约定：实现只抛 `SyncBackendError`（分类错误），网络 / HTTP 细节留在实现内部。
 */

import { SyncPullPage, SyncPushResult, SyncRecord } from '../../model/Sync';

/** 同步失败分类：编排层据此给出可读提示，不据此做重试策略（下一批再做退避）。 */
export class SyncErrorKind {
  static readonly NETWORK: string = 'network';
  static readonly AUTH: string = 'auth';
  static readonly API: string = 'api';
  static readonly PARSE: string = 'parse';
  static readonly UNKNOWN: string = 'unknown';
}

export class SyncBackendError extends Error {
  readonly kind: string;

  constructor(kind: string, message: string) {
    super(message);
    this.kind = kind;
  }
}

export interface SyncBackend {
  /** 展示用名称（设置页显示当前同步目标）。 */
  readonly name: string;

  /** 拉取游标之后的记录；records 为空表示没有更多。 */
  pull(cursor: string, limit: number): Promise<SyncPullPage>;

  /** 推送本地记录；返回可标干净 / 需要重试的 key。 */
  push(records: SyncRecord[]): Promise<SyncPushResult>;

  /** 比较并选择更新的持久化游标。 */
  betterCursor(current: string, candidate: string): string;

  /** 清空远端数据（Mock / 调试用；真实后端应删除该方法或改为受限操作）。 */
  reset(): Promise<void>;
}
