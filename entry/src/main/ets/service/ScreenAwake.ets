/*
 * ScreenAwake.ets — 阅读时长亮（window.setWindowKeepScreenOn 的容错封装）。
 *
 * 阅读页在前台时保持常亮、离开时恢复；由设置项「阅读时常亮」控制。
 * 取窗口可能失败（窗口未就绪 / 权限），失败只记日志，不影响阅读。
 */

import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ScreenAwake';

export class ScreenAwake {
  /** 设置窗口是否常亮（best-effort，不抛异常）。 */
  async set(on: boolean, context: common.Context | undefined): Promise<void> {
    if (context === undefined) {
      return;
    }
    try {
      const mainWindow: window.Window = await window.getLastWindow(context);
      await mainWindow.setWindowKeepScreenOn(on);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setKeepScreenOn(%{public}s) failed: %{public}d', on ? 'true' : 'false', error.code);
    }
  }
}

/** 全局唯一实例。 */
export const screenAwake: ScreenAwake = new ScreenAwake();
