/*
 * Diagnostics.ets — 性能与故障诊断的纯模型 / 纯函数（便于单测）。
 *
 * 只做归类与排序，不读写偏好库、不依赖 Ability 生命周期；运行时状态与持久化在
 * service/DiagnosticsService.ets。
 */

import { FeedError } from '../common/constants/RssConstants';

/** 一次抓取中单个订阅源的耗时样本（仅内存，不落盘）。 */
export class FeedFetchSample {
  readonly feedId: string;
  readonly title: string;
  readonly durationMs: number;
  readonly ok: boolean;
  /** 失败时的 FeedError 值；成功为空串。 */
  readonly code: string;

  constructor(feedId: string, title: string, durationMs: number, ok: boolean, code: string) {
    this.feedId = feedId;
    this.title = title;
    this.durationMs = durationMs;
    this.ok = ok;
    this.code = code;
  }
}

/** 抓取失败的五类归因（界面按这五类展示，避免把错误码直接摊给用户）。 */
export class FetchFailureCategory {
  static readonly TIMEOUT: string = 'timeout';
  static readonly NETWORK: string = 'network';
  static readonly HTTP: string = 'http';
  static readonly CONTENT: string = 'content';
  static readonly OTHER: string = 'other';
}

/** 错误码 → 失败归因。 */
export function failureCategoryOf(code: FeedError): string {
  if (code === FeedError.TIMEOUT) {
    return FetchFailureCategory.TIMEOUT;
  }
  if (code === FeedError.NETWORK_ERROR) {
    return FetchFailureCategory.NETWORK;
  }
  if (code === FeedError.HTTP_ERROR) {
    return FetchFailureCategory.HTTP;
  }
  if (code === FeedError.PARSE_ERROR || code === FeedError.NOT_A_FEED || code === FeedError.EMPTY_RESPONSE) {
    return FetchFailureCategory.CONTENT;
  }
  return FetchFailureCategory.OTHER;
}

/** 上次退出原因的语义分类（数值取自 AbilityConstant.LastExitReason）。 */
export class ExitReasonKind {
  static readonly UNKNOWN: string = 'unknown';
  static readonly NORMAL: string = 'normal';
  static readonly JS_ERROR: string = 'jsError';
  static readonly CPP_CRASH: string = 'cppCrash';
  static readonly FREEZE: string = 'freeze';
  static readonly RESOURCE: string = 'resource';
  static readonly UPGRADE: string = 'upgrade';
  static readonly USER: string = 'user';
  static readonly OTHER: string = 'other';
}

/**
 * LastExitReason → 语义分类。
 * 0 UNKNOWN / 2 NORMAL / 3 CPP_CRASH / 4 JS_ERROR / 5 APP_FREEZE /
 * 6 PERFORMANCE_CONTROL / 7 RESOURCE_CONTROL / 8 UPGRADE / 9 USER_REQUEST / 10 SIGNAL。
 */
export function exitReasonKind(reason: number): string {
  if (reason === 2) {
    return ExitReasonKind.NORMAL;
  }
  if (reason === 4) {
    return ExitReasonKind.JS_ERROR;
  }
  if (reason === 3) {
    return ExitReasonKind.CPP_CRASH;
  }
  if (reason === 5) {
    return ExitReasonKind.FREEZE;
  }
  if (reason === 6 || reason === 7) {
    return ExitReasonKind.RESOURCE;
  }
  if (reason === 8) {
    return ExitReasonKind.UPGRADE;
  }
  if (reason === 9 || reason === 10) {
    return ExitReasonKind.USER;
  }
  if (reason === 0) {
    return ExitReasonKind.UNKNOWN;
  }
  return ExitReasonKind.OTHER;
}

/** 按耗时降序取前 N 个源（同一耗时保持输入顺序，结果稳定）。 */
export function topSlowFeeds(samples: FeedFetchSample[], limit: number): FeedFetchSample[] {
  if (limit <= 0) {
    return [];
  }
  const copy: FeedFetchSample[] = samples.slice();
  copy.sort((a: FeedFetchSample, b: FeedFetchSample) => b.durationMs - a.durationMs);
  return copy.slice(0, limit);
}

/** 平均每源耗时（0 个源时返回 0）。 */
export function averageDuration(totalMs: number, count: number): number {
  if (count <= 0 || totalMs <= 0) {
    return 0;
  }
  return Math.round(totalMs / count);
}
