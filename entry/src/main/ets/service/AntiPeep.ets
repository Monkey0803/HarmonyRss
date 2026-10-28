/*
 * AntiPeep.ets — 防窥保护（Device Security Kit 的 dlpAntiPeep）。
 *
 * 五条必须记住的约束（与真机验证一致）：
 * 1. 调任何 dlpAntiPeep 接口前先 canIUse('SystemCapability.Security.DlpAntiPeep')：
 *    不支持该 syscap 的设备上直接调用会抛异常把应用冲崩，而不是返回失败。
 * 2. 三层 gating：应用开关打开 → 系统开关打开（isDlpAntiPeepSwitchOn）→ 才订阅。
 * 3. 需要 system_basic 权限 DLP_GET_HIDE_STATUS（证书 ACL）。当前调试签名未申请该 ACL，
 *    接口会返回 201，此时按「不支持」隐藏开关；正式包申请 ACL 后可恢复。
 * 4. 订阅只在开关打开时存在；关掉 / 页面销毁都要 off。
 * 5. 识别不是确定性的，所以遮罩允许用户一键点掉（acknowledge）。
 *
 * @ObservedV2 + @Trace：界面直接读 antiPeep.peeking 就能在状态变化时刷新。
 */

import { dlpAntiPeep } from '@kit.DeviceSecurityKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

@ObservedV2
export class AntiPeepController {
  /** 系统当前是否报告「有人在看」。 */
  @Trace peeking: boolean = false;
  /** 设备是否具备该能力（不支持是粘性终态）。 */
  @Trace supported: boolean = true;
  @Trace subscribed: boolean = false;
  /** 系统「设置 > 隐私和安全」里的防窥保护开关。 */
  @Trace systemSwitchOn: boolean = false;
  /** 非空时为给用户看的原因说明。 */
  @Trace problem: string = '';

  /** 开关的开关：关掉即取消订阅；打开时带 context 可以拉起系统弹窗。 */
  async setEnabled(enabled: boolean, context?: common.UIAbilityContext): Promise<boolean> {
    if (!enabled) {
      this.stop();
      return false;
    }
    return await this.doOpen(context);
  }

  /** 取消订阅并清掉窥视状态。 */
  stop(): void {
    if (this.subscribed) {
      try {
        // @SuppressWarnings syscap
        dlpAntiPeep.off('dlpAntiPeep');
      } catch (err) {
        // 已经取消或系统侧收回订阅：本地状态照常清理。
      }
    }
    this.subscribed = false;
    this.peeking = false;
  }

  /** 「轻点任意位置继续」的落点：把隐藏状态钉住并立即恢复本地状态。 */
  acknowledge(): void {
    if (this.supported) {
      try {
        // @SuppressWarnings syscap
        dlpAntiPeep.passDlpAntiPeepInfo();
      } catch (err) {
        // 钉不住也要照常放行：遮罩由本地状态说了算。
      }
    }
    this.peeking = false;
  }

  private async doOpen(context?: common.UIAbilityContext): Promise<boolean> {
    try {
      if (!this.supported) {
        this.problem = '设备不支持防窥保护';
        return false;
      }
      if (!canIUse('SystemCapability.Security.DlpAntiPeep')) {
        this.supported = false;
        this.problem = '设备不支持防窥保护';
        return false;
      }
      this.supported = true;
      this.systemSwitchOn = await this.readSystemSwitch();
      if (!this.supported) {
        this.problem = '设备不支持防窥保护';
        return false;
      }
      if (!this.systemSwitchOn && context !== undefined) {
        await this.askSystemSwitch(context);
        this.systemSwitchOn = await this.readSystemSwitch();
      }
      if (!this.systemSwitchOn) {
        this.problem = '请在系统设置中开启防窥保护';
        return false;
      }
      if (this.subscribed) {
        return true;
      }
      // @SuppressWarnings syscap
      dlpAntiPeep.on('dlpAntiPeep', onAntiPeepStatus);
      this.subscribed = true;
      this.problem = '';
      // on 只管之后的变化，进页面时可能已经在被窥视：初值同步取一次。
      this.peeking = dlpAntiPeep.getDlpAntiPeepInfo() === dlpAntiPeep.DlpAntiPeepStatus.HIDE;
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('dlpAntiPeep open failed: ' + error.code.toString());
      this.subscribed = false;
      // 801 = 设备没这个能力；201 = 证书未带 ACL 权限（DLP_GET_HIDE_STATUS）。
      // 两种情况都按「不支持」处理，避免设置页出现一个点不动的开关。
      if (error.code === 801 || error.code === 201) {
        this.supported = false;
        this.problem = '设备或签名未授予防窥能力';
      } else {
        this.problem = '防窥保护暂时不可用';
      }
      return false;
    }
  }

  private async askSystemSwitch(context: common.UIAbilityContext): Promise<void> {
    try {
      await dlpAntiPeep.requestAntiPeepOptions(context);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('requestAntiPeepOptions failed: ' + error.code.toString());
      if (error.code === 801 || error.code === 201) {
        this.supported = false;
      }
    }
  }

  private async readSystemSwitch(): Promise<boolean> {
    try {
      // @SuppressWarnings syscap
      return await dlpAntiPeep.isDlpAntiPeepSwitchOn();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('isDlpAntiPeepSwitchOn failed: ' + error.code.toString());
      // 801 = 设备没这个能力。模拟器上 canIUse 照样返回 true，真正挡住的是这里。
      if (error.code === 801 || error.code === 201) {
        this.supported = false;
      }
      return false;
    }
  }

  /** 系统 live view 提醒；发不出去不算故障。回调写在类外，避免静态/模块函数里的 this。 */
  publishLiveView(): void {
    try {
      // @SuppressWarnings syscap
      dlpAntiPeep.publishAntiPeepInformation().catch((err: BusinessError) => {
        console.error('publishAntiPeepInformation failed: ' + err.code.toString());
      });
    } catch (err) {
      console.error('publishAntiPeepInformation threw');
    }
  }
}

/** 全局唯一实例。 */
export const antiPeep: AntiPeepController = new AntiPeepController();

function onAntiPeepStatus(status: dlpAntiPeep.DlpAntiPeepStatus): void {
  const was: boolean = antiPeep.peeking;
  antiPeep.peeking = status === dlpAntiPeep.DlpAntiPeepStatus.HIDE;
  if (antiPeep.peeking && !was) {
    antiPeep.publishLiveView();
  }
}
