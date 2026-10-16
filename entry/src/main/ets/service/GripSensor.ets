/*
 * GripSensor.ets — 智感握姿（Multimodal Awareness Kit 的 motion 模块）。
 *
 * 订阅 holdingHandChanged：系统识别出握持手后，界面把**主操作移到拇指够得着的一侧**
 * （左手握持时镜像）。只镜像左手 —— 右手握持就是界面本来的排布，未握持 / 双手 / 未识别
 * 一律保持原样，避免系统上报抖动时界面来回翻。
 *
 * 约束（与真机验证一致）：
 * - 权限是 ohos.permission.DETECT_GESTURE（normal + system_grant，装机即授予、不弹窗、不需要 ACL）；
 * - 设备不支持时订阅抛 801：开关仍按用户意愿保存，界面用 supported 说明「未生效」，不弹提示；
 * - 订阅与开关同生共死，不做常驻监听；页面销毁必须 off。
 */

import { motion } from '@kit.MultimodalAwarenessKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'GripSensor';

@ObservedV2
export class GripSensor {
  /** 设备是否具备该能力（探到 801 后是粘性 false，不再重复订阅）。 */
  @Trace supported: boolean = true;
  @Trace subscribed: boolean = false;
  /** 是否**左手**握持：只有它为 true 时才镜像主操作。 */
  @Trace gripLeft: boolean = false;

  setEnabled(enabled: boolean): void {
    if (!enabled) {
      this.stop();
      return;
    }
    this.start();
  }

  private start(): void {
    if (this.subscribed || !this.supported) {
      return;
    }
    try {
      motion.on('holdingHandChanged', onHoldingHandChanged);
      this.subscribed = true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'holdingHandChanged on failed: %{public}d', error.code);
      // 801 = 设备不支持智感握姿。文档里「设备不支持」与「系统开关未开」现象相同，
      // 应用侧区分不了，所以只把 801 当设备级终态。
      if (error.code === 801) {
        this.supported = false;
      }
    }
  }

  stop(): void {
    if (this.subscribed) {
      try {
        motion.off('holdingHandChanged');
      } catch (err) {
        // 已经取消或系统侧收回订阅：本地状态照常清理。
      }
    }
    this.subscribed = false;
    this.gripLeft = false;
  }
}

/** 全局唯一实例。 */
export const gripSensor: GripSensor = new GripSensor();

/** 回调写在类外，避免模块级函数里的 this。 */
function onHoldingHandChanged(status: motion.HoldingHandStatus): void {
  gripSensor.gripLeft = status === motion.HoldingHandStatus.LEFT_HAND_HELD;
}
