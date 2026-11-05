/*
 * WebEnginePrewarm.ets — ArkWeb 引擎预热。
 *
 * 首个 Web 组件创建时要动态加载内核，阅读页第一帧会因此慢一截。
 * 在应用启动后的空闲时机先调一次 initializeWebEngine()，把这段开销提前摊掉。
 *
 * 约束（见 SDK 文档）：
 *   - 必须在本进程创建任何 Web 组件之前、且在 UI 主线程调用；
 *   - 全局生效，一个应用生命周期只需调用一次。
 */

import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'WebEnginePrewarm';

class WebEnginePrewarm {
  private warmed: boolean = false;

  /** 预热 ArkWeb 引擎：幂等，失败只记日志，不影响后续 Web 组件的正常创建。 */
  warmUp(): void {
    if (this.warmed) {
      return;
    }
    this.warmed = true;
    try {
      webview.WebviewController.initializeWebEngine();
      hilog.info(DOMAIN, TAG, 'web engine prewarmed');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'prewarm failed: %{public}d', error.code);
    }
  }
}

export const webEnginePrewarm: WebEnginePrewarm = new WebEnginePrewarm();
