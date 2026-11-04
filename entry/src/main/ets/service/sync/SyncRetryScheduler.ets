/* 自动同步失败后的退避定时器；状态只属于 SyncService 的单个实例。 */
import { common } from '@kit.AbilityKit';
import { AutoSyncPolicy } from './AutoSyncPolicy';

export class SyncRetryScheduler {
  private timer: number = -1;
  private attempt: number = 0;

  schedule(context: common.Context, retry: (context: common.Context) => void): void {
    if (this.timer >= 0 || !AutoSyncPolicy.canRetry(this.attempt)) {
      return;
    }
    const delay: number = AutoSyncPolicy.retryDelay(this.attempt);
    this.attempt += 1;
    this.timer = setTimeout(() => {
      this.timer = -1;
      retry(context);
    }, delay);
  }

  clear(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.attempt = 0;
  }
}
