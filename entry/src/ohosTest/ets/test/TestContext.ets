/*
 * TestContext.ets — 测试进程可用的 UIAbilityContext 持有者。
 *
 * 说明：`abilityDelegator.getAppContext()` 在部分设备/版本上不是 getRdbStore 接受的上下文
 * （会报 401 Illegal context），所以由 TestAbility.onCreate 注入它自己的 UIAbilityContext。
 */

import { common } from '@kit.AbilityKit';

export class TestContext {
  static value: common.UIAbilityContext | undefined = undefined;
}
