/* 系统通知发布与点击动作的底层适配。 */
import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DeepLinkParams } from './DeepLink';
import { stableNotificationId } from './NotifyPolicy';

const DOMAIN: number = 0x0000;
const TAG: string = 'NotifyService';
const MAIN_ABILITY: string = 'EntryAbility';

function describeError(err: Object): string {
  const error: BusinessError = err as BusinessError;
  const message: string = error.message;
  return message !== undefined && message.length > 0 ? message : 'unknown error';
}

export class NotificationPublisher {
  groupSupported: boolean = true;

  /**
   * 发布一条通知的底层实现：内容、wantAgent（点击打开文章）、可选动作按钮。
   * 返回是否发布成功；带 groupName 发布失败时降级为不支持分组（由调用方补聚合）。
   */
  async publishNotification(context: common.Context, id: number, groupName: string,
    title: string, text: string, articleId: string, actions: boolean): Promise<boolean> {
    try {
      const normal: notificationManager.NotificationBasicContent = { title: title, text: text };
      const content: notificationManager.NotificationContent = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: normal
      };
      const request: notificationManager.NotificationRequest = { id: id, content: content };
      const useGroup: boolean = this.groupSupported && groupName.length > 0;
      if (useGroup) {
        request.groupName = groupName;
      }
      const agent: WantAgent | undefined = await this.buildWantAgent(
        context, articleId, '', id);
      if (agent !== undefined) {
        request.wantAgent = agent;
      }
      if (actions) {
        const buttons: Array<notificationManager.NotificationActionButton> =
          await this.buildActionButtons(context, articleId);
        if (buttons.length > 0) {
          request.actionButtons = buttons;
        }
      }
      await notificationManager.publish(request);
      return true;
    } catch (err) {
      if (this.groupSupported && groupName.length > 0) {
        this.groupSupported = false;
        hilog.warn(DOMAIN, TAG, 'publish with group failed, degrade to per-feed aggregate: %{public}s',
          describeError(err));
      } else {
        hilog.error(DOMAIN, TAG, 'publish failed: %{public}s', describeError(err));
      }
      return false;
    }
  }

  /** 「标记已读 / 收藏」两个动作按钮；某个 wantAgent 构建失败就跳过该按钮。 */
  private async buildActionButtons(context: common.Context, articleId: string):
    Promise<Array<notificationManager.NotificationActionButton>> {
    const buttons: Array<notificationManager.NotificationActionButton> = [];
    const markRead: WantAgent | undefined = await this.buildWantAgent(context, articleId,
      DeepLinkParams.ACTION_MARK_READ,
      stableNotificationId(articleId + ':' + DeepLinkParams.ACTION_MARK_READ));
    if (markRead !== undefined) {
      const label: string =
        context.resourceManager.getStringSync($r('app.string.notify_action_mark_read').id);
      buttons.push({ title: label, wantAgent: markRead });
    }
    const star: WantAgent | undefined = await this.buildWantAgent(context, articleId,
      DeepLinkParams.ACTION_STAR,
      stableNotificationId(articleId + ':' + DeepLinkParams.ACTION_STAR));
    if (star !== undefined) {
      const label: string =
        context.resourceManager.getStringSync($r('app.string.notify_action_star').id);
      buttons.push({ title: label, wantAgent: star });
    }
    return buttons;
  }

  /**
   * 构建点击通知 / 动作按钮要用的 wantAgent：带上文章 id（与可选的 action）。
   * requestCode 按「文章 + 动作」稳定派生：不同通知的 wantAgent 互不覆盖。
   * 构建失败返回 undefined（通知降级为不可点击）。
   */
  private async buildWantAgent(context: common.Context, articleId: string,
    action: string, requestCode: number): Promise<WantAgent | undefined> {
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
        requestCode: requestCode,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      return await wantAgent.getWantAgent(info);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'buildWantAgent failed: %{public}s', describeError(err));
      return undefined;
    }
  }

}
