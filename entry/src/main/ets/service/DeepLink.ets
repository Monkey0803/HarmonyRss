/*
 * DeepLink.ets — 从卡片 / 通知带进来的「要打开哪篇文章」。
 *
 * 时序问题：EntryAbility 收到 want（onCreate / onNewWant）时页面可能还没挂载、甚至还没创建，
 * 所以这里只暂存 id，由页面在挂载 / 回到前台时取走（take 即清空，避免重复跳转）。
 */

import { Want } from '@kit.AbilityKit';

/** 深链参数（卡片 router action、通知点击、通知动作按钮都走这一套）。 */
export class DeepLinkParams {
  /** 要打开 / 操作的文章 id。 */
  static readonly ARTICLE_ID: string = 'articleId';
  /** 附加动作；缺省表示「打开文章」。 */
  static readonly ACTION: string = 'action';
  /** 动作值：只把该文章标记已读，不开详情页。 */
  static readonly ACTION_MARK_READ: string = 'markRead';
}

/**
 * 应用已在运行时点卡片 / 通知走的是 onNewWant，页面不会重建、onPageShow 也不会触发，
 * 所以由 Ability 通过 eventHub 发一条通知，页面收到后立刻消费深链。
 */
export const DEEP_LINK_EVENT: string = 'harmonyRssDeepLink';

export class DeepLink {
  /** 待处理的文章 id；空串表示没有。 */
  private pendingArticleId: string = '';
  /** 待处理的动作（见 DeepLinkParams.ACTION_*）；空串表示「打开文章」。 */
  private pendingAction: string = '';

  /** 从 want 里解析深链参数（卡片 router action、通知点击都会带 want.parameters）。 */
  accept(want: Want): void {
    const parameters: Record<string, Object> | undefined = want.parameters;
    if (parameters === undefined) {
      return;
    }
    const raw: Object | undefined = parameters[DeepLinkParams.ARTICLE_ID];
    if (typeof raw === 'string' && raw.length > 0) {
      this.pendingArticleId = raw;
      const action: Object | undefined = parameters[DeepLinkParams.ACTION];
      this.pendingAction = typeof action === 'string' ? action : '';
    }
  }

  /** 取走待处理的动作（与 id 同时失效）。 */
  takeAction(): string {
    const action: string = this.pendingAction;
    this.pendingAction = '';
    return action;
  }

  /** 看一眼待处理的文章 id（不清空），用于「文章表还没读出来时先留着」。 */
  peek(): string {
    return this.pendingArticleId;
  }

  /** 取走待处理的文章 id（取一次就清空）。 */
  take(): string {
    const id: string = this.pendingArticleId;
    this.pendingArticleId = '';
    return id;
  }
}

/** 全局唯一实例（Ability 与页面同进程，直接共享）。 */
export const deepLink: DeepLink = new DeepLink();
