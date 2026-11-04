/* 音频播放的后台长时任务及点击返回入口。 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'MediaPlayerService';
const MAIN_ABILITY: string = 'EntryAbility';
const BACKGROUND_REQUEST_CODE: number = 3001;

export class MediaBackgroundTask {
  private running: boolean = false;

  /** 申请后台长时任务（AVSession 已接入，系统不会额外弹通知）。 */
  async start(context: common.UIAbilityContext | undefined): Promise<void> {
    if (context === undefined || this.running) {
      return;
    }
    try {
      const agent: WantAgent | undefined = await this.buildWantAgent(context);
      if (agent === undefined) {
        return;
      }
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.running = true;
    } catch (err) {
      this.logError('start background', err);
    }
  }

  /** 结束后台长时任务。 */
  async stop(context: common.UIAbilityContext | undefined): Promise<void> {
    if (context === undefined || !this.running) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (err) {
      this.logError('stop background', err);
    }
    this.running = false;
  }

  /** 后台任务点回应用用的 WantAgent。 */
  private async buildWantAgent(context: common.UIAbilityContext): Promise<WantAgent | undefined> {
    try {
      const want: Want = {
        bundleName: context.applicationInfo.name,
        abilityName: MAIN_ABILITY
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: BACKGROUND_REQUEST_CODE,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      return await wantAgent.getWantAgent(info);
    } catch (err) {
      this.logError('want agent', err);
      return undefined;
    }
  }

  private logError(action: string, err: Object): void {
    const error: BusinessError = err as BusinessError;
    hilog.warn(DOMAIN, TAG, '%{public}s failed: %{public}d %{public}s', action,
      typeof error.code === 'number' ? error.code : 0,
      error.message !== undefined ? error.message : '');
  }
}
