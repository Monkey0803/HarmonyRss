/*
 * HomeViewModel.ets — 首页的 UI 状态与点光源视效（@ObservedV2）。
 *
 * 点光源（hdsEffect.pointLight，UI Design Kit，6.0.0(20)+）把组件当作光源，照亮同一容器里的
 * 受光组件。光源类型优先级高于 options：同时设置 sourceType 与 options 时 options 不生效。
 *
 * 约束（详见 README）：
 * - 单组件最多同时受 12 个光源照亮；
 * - 光源位置固定在组件正中心、不随位移变化 —— 因此不要放在滚动组件里；
 * - 仅 Button / Toggle / Row / Column / Image / Flex / Stack / Select / Menu / MenuItem 支持。
 */

import { hdsEffect } from '@kit.UIDesignKit';
import { appSettings } from '../model/AppSettings';

@ObservedV2
export class HomeViewModel {
  /** 当前光源类型：按下时 BRIGHT，松手回到 NONE。 */
  @Trace lightSource: hdsEffect.PointLightSourceType = hdsEffect.PointLightSourceType.NONE;

  /** 按下：点亮光源（开关关掉时不点亮）。 */
  press(): void {
    this.lightSource = appSettings.pointLightEnabled
      ? hdsEffect.PointLightSourceType.BRIGHT
      : hdsEffect.PointLightSourceType.NONE;
  }

  /** 松手 / 取消：熄灭。 */
  release(): void {
    this.lightSource = hdsEffect.PointLightSourceType.NONE;
  }

  /** 光源组件的视效：自身发光 + 边缘受光；开关关掉时全部退化为 NONE。 */
  sourceEffect(): VisualEffect {
    const enabled: boolean = appSettings.pointLightEnabled;
    const effect: hdsEffect.PointLightEffect = {
      sourceType: enabled ? this.lightSource : hdsEffect.PointLightSourceType.NONE,
      illuminatedType: enabled
        ? hdsEffect.PointLightIlluminatedType.BORDER
        : hdsEffect.PointLightIlluminatedType.NONE
    };
    return new hdsEffect.HdsEffectBuilder().pointLight(effect).buildEffect();
  }

  /** 受光组件的视效：边缘 + 内容被照亮；开关关掉时不接受光照。 */
  illuminatedEffect(): VisualEffect {
    const effect: hdsEffect.PointLightEffect = {
      illuminatedType: appSettings.pointLightEnabled
        ? hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
        : hdsEffect.PointLightIlluminatedType.NONE
    };
    return new hdsEffect.HdsEffectBuilder().pointLight(effect).buildEffect();
  }
}

/** 全局唯一实例。 */
export const homeViewModel: HomeViewModel = new HomeViewModel();
