/*
 * AutoSyncPolicy.ets — 自动同步的节流与失败重试策略（纯函数，可单测）。
 *
 * 自动触发点有三个（冷启动 / 回前台 / 抓取完成），同一时段可能连续触发：
 * 用「距上次成功同步或上次尝试」的最小间隔把重复调用合并掉；
 * 失败后指数退避重试，次数用尽就交给下一次触发，不再空转。
 */

export class AutoSyncPolicy {
  /** 自动同步最小间隔：60 秒内的多次触发只跑一次。 */
  static readonly MIN_GAP_MS: number = 60 * 1000;
  /** 一次失败后最多再试 3 次（30s / 60s / 120s）。 */
  static readonly MAX_RETRIES: number = 3;
  /** 首次重试延迟，之后逐次翻倍。 */
  static readonly RETRY_BASE_MS: number = 30 * 1000;

  /**
   * 现在是否该跑。
   * @param lastAttemptAt 上次同步成功或尝试的时间（0 = 从未）
   * @param throttle false 用于失败重试：绕过最小间隔
   */
  static isDue(lastAttemptAt: number, now: number, throttle: boolean): boolean {
    if (!throttle) {
      return true;
    }
    if (lastAttemptAt <= 0) {
      return true;
    }
    return now - lastAttemptAt >= AutoSyncPolicy.MIN_GAP_MS;
  }

  static canRetry(attempt: number): boolean {
    return attempt < AutoSyncPolicy.MAX_RETRIES;
  }

  /** 第 attempt 次重试的延迟（attempt 从 0 开始，上限指数封顶防溢出）。 */
  static retryDelay(attempt: number): number {
    const safe: number = attempt <= 0 ? 0 : Math.min(attempt, 6);
    return AutoSyncPolicy.RETRY_BASE_MS * Math.pow(2, safe);
  }
}
