/*
 * DiagnosticsService.ets — 本地性能与故障诊断的运行时状态 + 偏好库持久化。
 *
 * 设计：
 *   - 只写应用私有偏好库（hds_diagnostics_v1），**不上传任何数据**；
 *   - 启动耗时：UIAbility.onCreate 的 launchUTCTime → Index 首屏后回调；
 *   - 抓取耗时：FeedViewModel.fetchFeeds 逐源采样，每轮汇总成功 / 失败与五类归因；
 *   - 崩溃归类不拦截异常：只读取系统给的 LaunchParam.lastExitReason / lastExitMessage，
 *     不改变系统默认的崩溃退出行为。
 *
 * 所有展示字段都是 @Trace：诊断页打开期间，抓取完成 / 开关变化会即时刷新。
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appSettings } from '../model/AppSettings';
import { FeedError } from '../common/constants/RssConstants';
import {
  FeedFetchSample,
  FetchFailureCategory,
  failureCategoryOf,
  topSlowFeeds
} from '../model/Diagnostics';

const DOMAIN: number = 0x0000;
const TAG: string = 'Diagnostics';
const STORE_NAME: string = 'hds_diagnostics_v1';
/** 单轮最多保留的逐源样本数（只用于「最慢的源」，避免异常大批量占内存）。 */
const MAX_SAMPLES: number = 500;
/** 「最慢的源」展示条数。 */
const SLOW_FEED_LIMIT: number = 3;

const KEY_LAST_FETCH_AT: string = 'lastFetchAt';
const KEY_LAST_FETCH_DURATION: string = 'lastFetchDuration';
const KEY_LAST_FETCH_TOTAL: string = 'lastFetchTotal';
const KEY_LAST_FETCH_OK: string = 'lastFetchOk';
const KEY_LAST_FETCH_FAILED: string = 'lastFetchFailed';
const KEY_FAIL_TIMEOUT: string = 'failTimeout';
const KEY_FAIL_NETWORK: string = 'failNetwork';
const KEY_FAIL_HTTP: string = 'failHttp';
const KEY_FAIL_CONTENT: string = 'failContent';
const KEY_FAIL_OTHER: string = 'failOther';
const KEY_LAST_FPS: string = 'lastFps';
const KEY_WORST_FRAME_MS: string = 'worstFrameMs';
const KEY_LAST_FRAME_AT: string = 'lastFrameAt';
/** 两次帧率采样之间的最小间隔：避免每次滑动都持续占用 displaySync。 */
const FRAME_SAMPLE_INTERVAL_MS: number = 30 * 1000;

/** 偏好库里的数字：非数字 / 非有限值一律回退。 */
function numberValue(raw: preferences.ValueType, fallback: number): number {
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    return raw;
  }
  return fallback;
}

@ObservedV2
export class DiagnosticsService {
  /** 本次进程的 UIAbility 启动时刻（毫秒时间戳）。 */
  @Trace startupAt: number = 0;
  /** 从系统记录的能力启动时刻到首屏回调的耗时（毫秒）；0 表示尚未测到。 */
  @Trace firstScreenMs: number = 0;
  /** 系统给的「上次退出原因」原始枚举值；-1 表示未知。 */
  @Trace lastExitReason: number = -1;
  /** 系统给的「上次退出详情」（可能为空串）。 */
  @Trace lastExitMessage: string = '';

  /** 最近一轮抓取统计。 */
  @Trace lastFetchAt: number = 0;
  @Trace lastFetchDurationMs: number = 0;
  @Trace lastFetchTotal: number = 0;
  @Trace lastFetchOk: number = 0;
  @Trace lastFetchFailed: number = 0;

  /** 最近一轮抓取的失败归因（五类）。 */
  @Trace failTimeout: number = 0;
  @Trace failNetwork: number = 0;
  @Trace failHttp: number = 0;
  @Trace failContent: number = 0;
  @Trace failOther: number = 0;

  /** 最近一轮最慢的源（仅内存）。 */
  @Trace slowFeeds: FeedFetchSample[] = [];
  /** 本次进程累计抓取轮数。 */
  @Trace sessionFetchRuns: number = 0;

  /** 最近一次列表滚动采样的帧率与最差单帧耗时。 */
  @Trace lastFps: number = 0;
  @Trace worstFrameMs: number = 0;
  @Trace lastFrameAt: number = 0;

  private store: preferences.Preferences | undefined = undefined;
  private initStarted: boolean = false;
  /** 从系统 launchUTCTime 或 onCreate 时刻算起，用作首屏耗时基准。 */
  private launchBaseAt: number = 0;
  private runActive: boolean = false;
  private runStartedAt: number = 0;
  private runSamples: FeedFetchSample[] = [];

  /** 打开偏好库并读回上次抓取统计；可重复调用，只初始化一次。 */
  init(context: common.Context): void {
    if (this.initStarted) {
      return;
    }
    this.initStarted = true;
    this.load(context).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'load failed: %{public}s', err.message);
    });
  }

  private async load(context: common.Context): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
      this.store = store;
      this.lastFetchAt = numberValue(store.getSync(KEY_LAST_FETCH_AT, 0), 0);
      this.lastFetchDurationMs = numberValue(store.getSync(KEY_LAST_FETCH_DURATION, 0), 0);
      this.lastFetchTotal = numberValue(store.getSync(KEY_LAST_FETCH_TOTAL, 0), 0);
      this.lastFetchOk = numberValue(store.getSync(KEY_LAST_FETCH_OK, 0), 0);
      this.lastFetchFailed = numberValue(store.getSync(KEY_LAST_FETCH_FAILED, 0), 0);
      this.failTimeout = numberValue(store.getSync(KEY_FAIL_TIMEOUT, 0), 0);
      this.failNetwork = numberValue(store.getSync(KEY_FAIL_NETWORK, 0), 0);
      this.failHttp = numberValue(store.getSync(KEY_FAIL_HTTP, 0), 0);
      this.failContent = numberValue(store.getSync(KEY_FAIL_CONTENT, 0), 0);
      this.failOther = numberValue(store.getSync(KEY_FAIL_OTHER, 0), 0);
      this.lastFps = numberValue(store.getSync(KEY_LAST_FPS, 0), 0);
      this.worstFrameMs = numberValue(store.getSync(KEY_WORST_FRAME_MS, 0), 0);
      this.lastFrameAt = numberValue(store.getSync(KEY_LAST_FRAME_AT, 0), 0);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'open diagnostics store failed: %{public}d', error.code);
    }
  }

  /**
   * 记录一次 Ability 启动。
   * @param launchUtcTime 系统给的 UIAbility 启动 UTC 时间（API 23，0 = 不可用）
   * @param exitReason 上次退出原因（AbilityConstant.LastExitReason）
   * @param exitMessage 上次退出详情
   */
  markLaunch(launchUtcTime: number, exitReason: number, exitMessage: string): void {
    this.startupAt = Date.now();
    this.launchBaseAt = launchUtcTime > 0 ? launchUtcTime : this.startupAt;
    this.firstScreenMs = 0;
    this.lastExitReason = exitReason;
    this.lastExitMessage = exitMessage;
    hilog.info(DOMAIN, TAG, 'launch at %{public}d, lastExitReason=%{public}d', this.startupAt, exitReason);
  }

  /** 首屏后调用：记录启动到首屏耗时（只记录一次）。 */
  markFirstScreen(): void {
    if (this.firstScreenMs > 0 || this.launchBaseAt <= 0) {
      return;
    }
    const elapsed: number = Date.now() - this.launchBaseAt;
    this.firstScreenMs = elapsed > 0 ? elapsed : 0;
    if (appSettings.diagnosticsEnabled) {
      hilog.info(DOMAIN, TAG, 'first screen in %{public}d ms', this.firstScreenMs);
    }
  }

  /** 开始一轮抓取统计（关闭诊断时直接忽略）。 */
  beginFetch(total: number): void {
    if (!appSettings.diagnosticsEnabled) {
      return;
    }
    this.runActive = true;
    this.runStartedAt = Date.now();
    this.runSamples = [];
    this.lastFetchTotal = total;
    this.lastFetchOk = 0;
    this.lastFetchFailed = 0;
    this.failTimeout = 0;
    this.failNetwork = 0;
    this.failHttp = 0;
    this.failContent = 0;
    this.failOther = 0;
    this.sessionFetchRuns += 1;
  }

  /** 记录单个源的抓取结果（未开始统计时忽略）。 */
  recordFeed(feedId: string, title: string, durationMs: number, ok: boolean, code: FeedError): void {
    if (!this.runActive) {
      return;
    }
    if (this.runSamples.length < MAX_SAMPLES) {
      this.runSamples.push(new FeedFetchSample(feedId, title, durationMs, ok, ok ? '' : code));
    }
    if (ok) {
      this.lastFetchOk += 1;
      return;
    }
    this.lastFetchFailed += 1;
    const category: string = failureCategoryOf(code);
    if (category === FetchFailureCategory.TIMEOUT) {
      this.failTimeout += 1;
    } else if (category === FetchFailureCategory.NETWORK) {
      this.failNetwork += 1;
    } else if (category === FetchFailureCategory.HTTP) {
      this.failHttp += 1;
    } else if (category === FetchFailureCategory.CONTENT) {
      this.failContent += 1;
    } else {
      this.failOther += 1;
    }
  }

  /** 结束一轮抓取：汇总耗时、取最慢的源并落盘。 */
  endFetch(): void {
    if (!this.runActive) {
      return;
    }
    this.runActive = false;
    const duration: number = Date.now() - this.runStartedAt;
    this.lastFetchAt = this.runStartedAt;
    this.lastFetchDurationMs = duration;
    this.slowFeeds = topSlowFeeds(this.runSamples, SLOW_FEED_LIMIT);
    this.runSamples = [];
    if (appSettings.diagnosticsEnabled) {
      hilog.info(DOMAIN, TAG,
        'fetch done in %{public}d ms: total=%{public}d ok=%{public}d failed=%{public}d',
        duration, this.lastFetchTotal, this.lastFetchOk, this.lastFetchFailed);
      this.persist();
    }
  }

  /** 清除抓取统计（保留本次启动信息与系统给的上次退出原因）。 */
  clear(): void {
    this.lastFetchAt = 0;
    this.lastFetchDurationMs = 0;
    this.lastFetchTotal = 0;
    this.lastFetchOk = 0;
    this.lastFetchFailed = 0;
    this.failTimeout = 0;
    this.failNetwork = 0;
    this.failHttp = 0;
    this.failContent = 0;
    this.failOther = 0;
    this.slowFeeds = [];
    this.sessionFetchRuns = 0;
    this.lastFps = 0;
    this.worstFrameMs = 0;
    this.lastFrameAt = 0;
    this.persist();
  }

  /** 是否值得开始一次帧率采样（诊断关闭 / 距上次不足 30s 时跳过）。 */
  canSampleFrames(): boolean {
    return appSettings.diagnosticsEnabled && Date.now() - this.lastFrameAt >= FRAME_SAMPLE_INTERVAL_MS;
  }

  /** 记录一次列表滚动采样（采样器在 2s 窗口结束后调用）。 */
  recordFrameSample(fps: number, worstGapMs: number): void {
    if (!appSettings.diagnosticsEnabled || fps <= 0) {
      return;
    }
    this.lastFps = Math.round(fps * 10) / 10;
    this.worstFrameMs = Math.round(worstGapMs * 10) / 10;
    this.lastFrameAt = Date.now();
    hilog.info(DOMAIN, TAG, 'scroll fps=%{public}d worst=%{public}d ms',
      Math.round(this.lastFps), Math.round(this.worstFrameMs));
    this.persist();
  }

  private persist(): void {
    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(KEY_LAST_FETCH_AT, this.lastFetchAt);
      store.putSync(KEY_LAST_FETCH_DURATION, this.lastFetchDurationMs);
      store.putSync(KEY_LAST_FETCH_TOTAL, this.lastFetchTotal);
      store.putSync(KEY_LAST_FETCH_OK, this.lastFetchOk);
      store.putSync(KEY_LAST_FETCH_FAILED, this.lastFetchFailed);
      store.putSync(KEY_FAIL_TIMEOUT, this.failTimeout);
      store.putSync(KEY_FAIL_NETWORK, this.failNetwork);
      store.putSync(KEY_FAIL_HTTP, this.failHttp);
      store.putSync(KEY_FAIL_CONTENT, this.failContent);
      store.putSync(KEY_FAIL_OTHER, this.failOther);
      store.putSync(KEY_LAST_FPS, this.lastFps);
      store.putSync(KEY_WORST_FRAME_MS, this.worstFrameMs);
      store.putSync(KEY_LAST_FRAME_AT, this.lastFrameAt);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'persist failed: %{public}d', error.code);
      return;
    }
    store.flush().catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'flush failed: %{public}d', err.code);
    });
  }
}

/** 全局唯一实例。 */
export const diagnostics: DiagnosticsService = new DiagnosticsService();
