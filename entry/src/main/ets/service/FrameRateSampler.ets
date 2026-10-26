/*
 * FrameRateSampler.ets — 列表滚动帧率的轻量采样器。
 *
 * 只在用户开始滚动列表时启动一个 2 秒窗口（30 秒内最多一次），
 * 用 displaySync 的帧回调统计平均 FPS 与最差单帧间隔；结果交给 DiagnosticsService。
 * 采样失败 / 平台不支持 / 诊断关闭时静默跳过，不影响滚动。
 */

import { displaySync } from '@kit.ArkGraphics2D';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { diagnostics } from './DiagnosticsService';

const DOMAIN: number = 0x0000;
const TAG: string = 'FrameRate';
/** 单次采样窗口。 */
const SAMPLE_WINDOW_MS: number = 2000;

export class FrameRateSampler {
  private sync: displaySync.DisplaySync | undefined = undefined;
  private timer: number = -1;
  private active: boolean = false;
  private firstNs: number = 0;
  private prevNs: number = 0;
  private frames: number = 0;
  private worstGapMs: number = 0;

  /** 帧回调引用必须稳定，off / 复用同一个实例时才能正确配对。 */
  private readonly onFrame = (info: displaySync.IntervalInfo): void => {
    if (!this.active) {
      return;
    }
    const timestamp: number = info.timestamp;
    if (this.firstNs === 0) {
      this.firstNs = timestamp;
    } else if (this.prevNs > 0) {
      const gapMs: number = (timestamp - this.prevNs) / 1000000;
      if (gapMs > this.worstGapMs) {
        this.worstGapMs = gapMs;
      }
    }
    this.prevNs = timestamp;
    this.frames += 1;
  };

  /** 开始采样；已在采样中 / 距上次不足 30s / 诊断关闭时直接返回。 */
  start(): void {
    if (this.active || !diagnostics.canSampleFrames()) {
      return;
    }
    try {
      if (this.sync === undefined) {
        this.sync = displaySync.create();
        this.sync.on('frame', this.onFrame);
      }
      this.reset();
      this.active = true;
      this.sync.start();
      this.timer = setTimeout(() => {
        this.finish();
      }, SAMPLE_WINDOW_MS);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'start failed: %{public}d', error.code);
      this.cleanup();
    }
  }

  /** 提前结束（页面销毁时调用）。 */
  stop(): void {
    if (this.active) {
      this.finish();
    }
  }

  private finish(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.active = false;
    this.stopSync();
    const frames: number = this.frames;
    const elapsedNs: number = this.prevNs - this.firstNs;
    const worst: number = this.worstGapMs;
    this.reset();
    if (frames >= 2 && elapsedNs > 0) {
      const fps: number = (frames - 1) * 1000000000 / elapsedNs;
      diagnostics.recordFrameSample(fps, worst);
    }
  }

  private stopSync(): void {
    const sync: displaySync.DisplaySync | undefined = this.sync;
    if (sync === undefined) {
      return;
    }
    try {
      sync.stop();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'stop failed: %{public}d', error.code);
    }
  }

  private cleanup(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.active = false;
    this.stopSync();
    this.reset();
  }

  private reset(): void {
    this.firstNs = 0;
    this.prevNs = 0;
    this.frames = 0;
    this.worstGapMs = 0;
  }
}

/** 全局唯一实例。 */
export const frameRateSampler: FrameRateSampler = new FrameRateSampler();
