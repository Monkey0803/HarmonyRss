import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { safeArea } from '../service/SafeAreaController';
import { deepLink, DEEP_LINK_EVENT } from '../service/DeepLink';

const DOMAIN: number = 0x0000;
const TAG: string = 'HdsEntry';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 卡片 / 通知带进来的深链参数先存起来，页面挂载后再取。
    deepLink.accept(want);
    // 主题由设置页控制；这里先跟随系统，恢复订阅后由 ThemeController 覆盖。
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setColorMode failed');
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}d', err.code);
        return;
      }
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      // 全局沉浸：内容延伸至系统栏区域。
      mainWindow.setWindowLayoutFullScreen(true).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}d', e.code);
      });
      // 全屏沉浸：不做系统状态栏 / 导航条避让。这里只读取顶部系统栏与标题栏高度，
      // 供可滚动内容计算首屏下移量（页签栏避让高度来自 resources 的 float）。
      safeArea.attach(this.context, mainWindow);
      // 窗口背景色兜底（与背景图主色调一致），避免页面切换时闪白。
      // 颜色不硬编码：从 start_window_background 资源读取（含深浅色适配），转成 #AARRGGBB。
      const colorValue: number = this.context.resourceManager.getColorSync($r('app.color.start_window_background').id);
      const fallback: string = '#' + (colorValue >>> 0).toString(16).padStart(8, '0').toUpperCase();
      mainWindow.setWindowBackgroundColor(fallback);
    });
  }

  /** 应用已在运行时再次被拉起（点卡片 / 点通知）：want 走这里，同样先存深链。 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    deepLink.accept(want);
    // 页面可能已经在最前面：onPageShow 不会再触发，用事件通知它立刻消费。
    try {
      this.context.eventHub.emit(DEEP_LINK_EVENT);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'emit deep link failed');
    }
  }

  onDestroy(): void {
    safeArea.detach();
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }
}
