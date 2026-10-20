/*
 * ShareHandoff.ets — 分享数据从「接收方（Ability）」到「界面」的一次性交接。
 *
 * 接收方（EntryAbility / ShareAbility）解析出地址后写入这里；界面注册 onReady 回调消费。
 * 之所以不直接用旧式存储对象传参（属 V1）：冷启动时解析是异步的，界面可能早于解析完成挂载，
 * 因此这里同时支持「已就绪立即回调」与「未就绪注册等待」两种时序。
 */

export class ShareHandoff {
  private urls: string[] = [];
  private listeners: Array<(urls: string[]) => void> = [];
  private consumed: boolean = false;

  /** 写入本次分享解析出的地址；若有等待者，立即回调（一次性）。 */
  set(urls: string[]): void {
    this.urls = urls;
    this.consumed = false;
    if (urls.length === 0 || this.listeners.length === 0) {
      return;
    }
    const pending: Array<(urls: string[]) => void> = this.listeners;
    this.listeners = [];
    this.consumed = true;
    for (let i = 0; i < pending.length; i += 1) {
      pending[i](urls);
    }
  }

  /**
   * 注册消费回调：若地址已就绪则立即回调，否则等 set 时回调。一次性。
   * 返回是否「立即消费」（调用方据此决定是否已经能打开面板）。
   */
  onReady(listener: (urls: string[]) => void): boolean {
    if (this.urls.length > 0 && !this.consumed) {
      this.consumed = true;
      const urls: string[] = this.urls;
      listener(urls);
      return true;
    }
    this.listeners.push(listener);
    return false;
  }

  /** 取出并清空（一次性消费）。 */
  take(): string[] {
    const result: string[] = this.urls;
    this.urls = [];
    return result;
  }
}

/** 全局唯一实例。 */
export const shareHandoff: ShareHandoff = new ShareHandoff();
