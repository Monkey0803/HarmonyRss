/*
 * ToastUtil.ets — 安全提示（showToast 的容错封装）。
 *
 * `UIContext.getPromptAction().showToast` 被标注为可能抛异常，ArkTS 要求调用点必须处理
 * （只在 try/finally 里不算，必须有 catch）。提示失败不应该影响业务流程，因此统一在这里
 * 吞掉异常并记日志，调用方只关心「要提示什么」。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ToastUtil';

export class ToastUtil {
  /** 弹一条 Toast；失败只记日志，不向上抛。 */
  static show(uiContext: UIContext, message: ResourceStr): void {
    try {
      uiContext.getPromptAction().showToast({ message: message });
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'showToast failed: %{public}d', error.code);
    }
  }
}
