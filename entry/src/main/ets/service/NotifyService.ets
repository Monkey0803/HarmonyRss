/*
 * NotifyService.ets — 新文章通知（Model 层：屏蔽通知能力）。
 *
 * 使用场景是「后台定时抓取发现了新文章」：设置开启且系统已授权时才发通知，点击通知打开应用。
 * 通知文案要本地化，但 NotificationContent 只收 string，所以用 resourceManager 的格式化取串。
 * 任何一步失败都静默降级（通知只是锦上添花，不能影响抓取本身）。
 */

import { notificationManager } from '@kit.NotificationKit';
import { Article } from '../model/Feed';
import { DeepLinkParams } from './DeepLink';
import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'NotifyService';
/** 固定通知 id：同一 id 重复发布只更新同一条，不会刷屏。 */
const NOTIFY_ID: number = 1001;
/** 点击通知要拉起的页面。 */
const MAIN_ABILITY: string = 'EntryAbility';

export class NotifyService {
  /** 是否已获得通知授权。 */
  isEnabled(): boolean {
    try {
      return notificationManager.isNotificationEnabledSync();
    } catch (err) {
      return false;
    }
  }

  /** 首次开启时向用户申请通知授权；返回最终是否可用。 */
  async requestEnable(context: common.UIAbilityContext): Promise<boolean> {
    try {
      if (this.isEnabled()) {
        return true;
      }
      await notificationManager.requestEnableNotification(context);
      return this.isEnabled();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'requestEnable failed: %{public}d', error.code);
      return false;
    }
  }

  /**
   * 发布「N 篇新文章」通知。
   *
   * - 文案按来源聚合：单源直接给来源名 + 一条标题；多源给「来源名 等 M 个源」+ 一条标题；
   * - wantAgent 带上首篇文章 id → 点击直达该文章；
   * - 附一个「标记已读」动作按钮（同一个 id + action=markRead）。
   *
   * 未授权或 count 为 0 时直接返回；任何一步失败都静默降级（通知不能影响抓取本身）。
   */
  async publishNewArticles(context: common.Context, added: Article[]): Promise<void> {
    const count: number = added.length;
    if (count <= 0 || !this.isEnabled()) {
      return;
    }
    try {
      const title: string = context.resourceManager.getStringSync(
        $r('app.string.notify_new_title').id, count);
      const text: string = context.resourceManager.getStringSync(
        $r('app.string.notify_new_text').id,
        this.sourceSummary(added), added[0].title);
      const normal: notificationManager.NotificationBasicContent = { title: title, text: text };
      const content: notificationManager.NotificationContent = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: normal
      };
      const request: notificationManager.NotificationRequest = {
        id: NOTIFY_ID,
        content: content
      };
      const articleId: string = added[0].id;
      const agent: WantAgent | undefined = await this.buildWantAgent(context, articleId, '');
      if (agent !== undefined) {
        request.wantAgent = agent;
        const markRead: WantAgent | undefined =
          await this.buildWantAgent(context, articleId, DeepLinkParams.ACTION_MARK_READ);
        if (markRead !== undefined) {
          const markReadLabel: string =
            context.resourceManager.getStringSync($r('app.string.notify_action_mark_read').id);
          const buttons: Array<notificationManager.NotificationActionButton> = [
            { title: markReadLabel, wantAgent: markRead }
          ];
          request.actionButtons = buttons;
        }
      }
      await notificationManager.publish(request);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'publish failed: %{public}d', error.code);
    }
  }

  /**
   * 文案里的来源部分：单源用来源名，多源用「来源名 等 M 个源」。
   * 按来源去重（同一个源的多篇只算一个），来源名取首篇的 feedTitle。
   */
  private sourceSummary(added: Article[]): string {
    const sources: string[] = [];
    for (let i = 0; i < added.length; i += 1) {
      const name: string = added[i].feedTitle;
      if (name.length > 0 && sources.indexOf(name) < 0) {
        sources.push(name);
      }
    }
    if (sources.length === 0) {
      return '';
    }
    if (sources.length === 1) {
      return sources[0];
    }
    return sources[0] + ' +' + (sources.length - 1).toString();
  }

  /**
   * 构建点击通知 / 动作按钮要用的 wantAgent：带上文章 id（与可选的 action）。
   * 构建失败返回 undefined（通知降级为不可点击）。
   */
  private async buildWantAgent(context: common.Context, articleId: string,
    action: string): Promise<WantAgent | undefined> {
    try {
      const parameters: Record<string, Object> = {};
      if (articleId.length > 0) {
        parameters[DeepLinkParams.ARTICLE_ID] = articleId;
      }
      if (action.length > 0) {
        parameters[DeepLinkParams.ACTION] = action;
      }
      const want: Want = {
        bundleName: context.applicationInfo.name,
        abilityName: MAIN_ABILITY,
        parameters: parameters
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      return await wantAgent.getWantAgent(info);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'buildWantAgent failed: %{public}d', error.code);
      return undefined;
    }
  }
}

/** 全局唯一实例。 */
export const notifyService: NotifyService = new NotifyService();
