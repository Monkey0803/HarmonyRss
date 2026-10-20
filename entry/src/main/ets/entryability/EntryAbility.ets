import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { safeArea } from '../service/SafeAreaController';
import { shareIntent } from '../service/ShareIntent';
import { shareHandoff } from '../service/ShareHandoff';

const DOMAIN: number = 0x0000;
const TAG: string = 'HdsEntry';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 主题由设置页控制；这里先跟随系统，恢复订阅后由 ThemeController 覆盖。
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setColorMode failed');
    }
    // 冷启动也可能来自「分享」（skills 声明了 sendData/viewData）。
    this.handleSharedData(want);
  }

  /** 热启动（应用已在运行）时收到的新 want：同样可能是分享。 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleSharedData(want);
  }

  /**
   * 解析分享进来的内容并交给界面：取出地址写入 shareHandoff，界面据此打开「添加订阅源」面板并预填。
   * 不是分享（普通启动）时记录里没有可订阅地址，静默跳过即可。
   */
  private handleSharedData(want: Want): void {
    systemShare.getSharedData(want)
      .then((data: systemShare.SharedData) => {
        shareHandoff.set(shareIntent.extractFromSharedData(data));
      })
      .catch((error: BusinessError) => {
        // 普通启动没有分享数据，getSharedData 会失败：属正常情况，不打扰用户。
        hilog.info(DOMAIN, TAG, 'no shared data: %{public}d', error.code);
      });
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

  onDestroy(): void {
    safeArea.detach();
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }
}
