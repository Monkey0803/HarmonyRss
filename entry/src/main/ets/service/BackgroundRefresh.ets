/*
 * BackgroundRefresh.ets — 后台定时抓取的注册 / 注销（WorkScheduler）。
 *
 * 与前台自动刷新（回前台按间隔判断）互补：这里交给系统在满足条件时唤醒，
 * 由 workscheduler/RssWorkScheduler.ets 执行一次性抓取。
 * 间隔为「关闭」时注销任务；系统对重复周期有下限（20 分钟），更短的值会被抬到下限。
 */

import { workScheduler } from '@kit.BackgroundTasksKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appSettings } from '../model/AppSettings';
import { AutoRefreshMinutes } from '../common/constants/SettingsConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'BackgroundRefresh';

/** 后台任务固定 id（同一 id 重复注册会覆盖）。 */
const WORK_ID: number = 1001;
/** 扩展能力名，必须与 module.json5 里声明的一致。 */
const ABILITY_NAME: string = 'RssWorkScheduler';
/** 系统对 repeatCycleTime 的下限（毫秒）。 */
const MIN_CYCLE_MS: number = 20 * 60 * 1000;

export class BackgroundRefresh {
  /** 按当前设置同步后台任务：关闭 → 注销，否则按所选间隔注册（不足下限则抬到下限）。 */
  sync(context: common.Context): void {
    const minutes: number = AutoRefreshMinutes.of(appSettings.autoRefresh);
    const work: workScheduler.WorkInfo = {
      workId: WORK_ID,
      bundleName: context.applicationInfo.name,
      abilityName: ABILITY_NAME,
      isPersisted: true,
      isRepeat: true,
      repeatCycleTime: minutes === AutoRefreshMinutes.OFF
        ? MIN_CYCLE_MS
        : Math.max(minutes * 60 * 1000, MIN_CYCLE_MS),
      repeatCount: 0,
      networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
      isCharging: false
    };
    try {
      if (minutes === AutoRefreshMinutes.OFF) {
        workScheduler.stopWork(work, true);
        return;
      }
      workScheduler.startWork(work);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'sync work failed: %{public}d', error.code);
    }
  }
}

/** 全局唯一实例。 */
export const backgroundRefresh: BackgroundRefresh = new BackgroundRefresh();
