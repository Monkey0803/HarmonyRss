import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { Hypium } from '@ohos/hypium';
import testsuite from '../test/List.test';
import { TestContext } from '../test/TestContext';

const ON_DESTROY_ERROR: number = -2;

export default class TestAbility extends UIAbility {
  abilityDelegator: abilityDelegatorRegistry.AbilityDelegator;

  constructor() {
    super();
    this.abilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 给需要真实 UIAbilityContext 的用例（如 RDB 压测）注入上下文。
    TestContext.value = this.context;
    const args: abilityDelegatorRegistry.AbilityDelegatorArgs = abilityDelegatorRegistry.getArguments();
    hilog.info(0x0000, 'testTag', '%{public}s', 'start run testcase!!!');
    Hypium.hypiumTest(this.abilityDelegator, args, testsuite);
  }

  onDestroy(): void {
    this.abilityDelegator.finishTest('TestAbility onDestroy unexpectedly!', ON_DESTROY_ERROR, () => {
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('testability/pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'testTag', 'loadContent failed: %{public}s', JSON.stringify(err) ?? '');
      }
    });
  }
}
