/* Record the first display frame after the root page appears. */
import { displaySync } from '@kit.ArkGraphics2D';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { diagnostics } from './DiagnosticsService';

export class FirstFrameSampler {
  private sync: displaySync.DisplaySync | undefined = undefined;
  private fallbackTimer: number = -1;
  private stopTimer: number = -1;
  private lastFrameAt: number = 0;
  private maxFrameGapMs: number = 0;
  private frames: number = 0;
  private contentReady: boolean = false;
  private contentFrameRecorded: boolean = false;

  private readonly onFrame = (info: displaySync.IntervalInfo): void => {
    const now: number = Date.now();
    if (this.contentReady && !this.contentFrameRecorded) {
      this.contentFrameRecorded = true;
      diagnostics.markFirstScreen();
      if (this.fallbackTimer >= 0) {
        clearTimeout(this.fallbackTimer);
        this.fallbackTimer = -1;
      }
    }
    if (this.frames > 0) {
      const gap: number = now - this.lastFrameAt;
      this.maxFrameGapMs = Math.max(this.maxFrameGapMs, gap);
      if (gap >= 80) {
        hilog.warn(0x0000, 'FirstFrameSampler', 'startup slowFrame gap=%{public}dms', gap);
      }
    }
    this.lastFrameAt = now;
    this.frames += 1;
  };

  start(): void {
    if (this.sync !== undefined) {
      return;
    }
    this.frames = 0;
    this.lastFrameAt = 0;
    this.maxFrameGapMs = 0;
    this.contentReady = false;
    this.contentFrameRecorded = false;
    try {
      const sync: displaySync.DisplaySync = displaySync.create();
      sync.on('frame', this.onFrame);
      this.sync = sync;
      sync.start();
      this.stopTimer = setTimeout(() => this.stop(), 3000);
    } catch (err) {
      this.stop();
    }
  }

  /** 数据已发布给首页；下一帧才算「首次有内容」，空帧不能作为首屏结果。 */
  markContentReady(): void {
    if (this.contentReady) {
      return;
    }
    this.contentReady = true;
    this.fallbackTimer = setTimeout(() => {
      diagnostics.markFirstScreen();
    }, this.sync === undefined ? 0 : 1500);
  }

  stop(): void {
    if (this.fallbackTimer >= 0) {
      clearTimeout(this.fallbackTimer);
      this.fallbackTimer = -1;
    }
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
    const sync: displaySync.DisplaySync | undefined = this.sync;
    this.sync = undefined;
    if (sync !== undefined) {
      try {
        sync.stop();
        sync.off('frame', this.onFrame);
      } catch (err) {
      }
      hilog.info(0x0000, 'FirstFrameSampler', 'startup frames=%{public}d worstGap=%{public}dms',
        this.frames, this.maxFrameGapMs);
    }
  }
}
