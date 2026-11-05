import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { safeArea } from '../service/SafeAreaController';
import { deepLink, DEEP_LINK_EVENT } from '../service/DeepLink';
import { shareIntent } from '../service/ShareIntent';
import { shareHandoff } from '../service/ShareHandoff';
import { diagnostics } from '../service/DiagnosticsService';
import { readingContinuation } from '../service/ReadingContinuation';
import { themePalette } from '../model/ThemePalette';
import { Toast } from '@monkey0803/toast-kit';
import { Keyboard } from '@monkey0803/keyboard-kit';
import { setupToast } from '../common/utils/ToastSetup';
import { webEnginePrewarm } from '../service/WebEnginePrewarm';

const DOMAIN: number = 0x0000;
const TAG: string = 'HdsEntry';
/** 首帧后延迟预热 ArkWeb：避开冷启动关键路径，又不至于让用户点进阅读页时还没预热完。 */
const PREWARM_DELAY_MS: number = 500;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 启动时刻 / 上次退出原因只读系统给的值：不注册全局异常观测器，不改变默认崩溃行为。
    diagnostics.markLaunch(launchParam.launchUTCTime ?? 0,
      launchParam.lastExitReason, launchParam.lastExitMessage ?? '');
    diagnostics.init(this.context);
    // 卡片 / 通知带进来的深链参数先存起来，页面挂载后再取。
    deepLink.accept(want);
    readingContinuation.accept(want, launchParam);
    // 主题由设置页控制；这里先跟随系统，恢复订阅后由 ThemeController 覆盖。
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setColorMode failed');
    }
    // 主题色是运行时色值，需自行记录当前深浅色；设置恢复后 ThemeController 会覆盖。
    themePalette.setDark(
      this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    // 冷启动也可能是「分享」进来（skills 声明了 sendData/viewData）。
    this.handleSharedData(want);
  }

  /** 系统深浅色变化：同步运行时调色板（设置页显式浅/深色时不会被系统覆盖）。 */
  onConfigurationUpdate(newConfig: Configuration): void {
    if (newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      themePalette.setDark(true);
    } else if (newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      themePalette.setDark(false);
    }
  }

  /**
   * 应用已在运行时再次被拉起：want 走这里 —— 既可能是点卡片 / 点通知的深链，也可能是「分享」。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    deepLink.accept(want);
    readingContinuation.accept(want, launchParam);
    // 页面可能已经在最前面：onPageShow 不会再触发，用事件通知它立刻消费。
    try {
      this.context.eventHub.emit(DEEP_LINK_EVENT);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'emit deep link failed');
    }
    // 分享（热启动）从同一个入口处理。
    this.handleSharedData(want);
  }

  /**
   * 解析分享进来的内容并交给界面：取出地址写入 shareHandoff，界面据此打开网页保存面板并预填。
   * 不是分享（普通启动 / 深链启动）时记录里没有可订阅地址，静默跳过即可。
   */
  private handleSharedData(want: Want): void {
    systemShare.getSharedData(want)
      .then((data: systemShare.SharedData) => {
        const shared: string[] = shareIntent.extractFromSharedData(data);
        // 分享记录里没有 http(s) 地址时，退回对 want 参数的尽力提取（与 ShareAbility 一致）。
        shareHandoff.set(shared.length > 0 ? shared : shareIntent.extractSharedUrls(want));
      })
      .catch((error: BusinessError) => {
        // 普通启动没有分享数据，getSharedData 会失败；但部分应用只把地址放进 want 参数，
        // 这里仍按参数提取一次，避免「分享到本应用却什么都不发生」。
        const fallback: string[] = shareIntent.extractSharedUrls(want);
        if (fallback.length > 0) {
          shareHandoff.set(fallback);
          return;
        }
        hilog.info(DOMAIN, TAG, 'no shared data: %{public}d', error.code);
      });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 全局 Toast：主窗口上下文一次注册，页面内直接 Toast.show 即可。
    Toast.init(windowStage);
    Keyboard.init(windowStage);
    setupToast();
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
      // 首帧后再预热 ArkWeb 内核：首个阅读页省掉引擎加载，冷启动关键路径不受影响。
      // initializeWebEngine 必须走 UI 主线程；这里在 loadContent 回调里延时调用，满足该约束。
      setTimeout((): void => {
        webEnginePrewarm.warmUp();
      }, PREWARM_DELAY_MS);
    });
  }

  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    return readingContinuation.write(wantParam);
  }

  /** 接续恢复不会调用 onWindowStageCreate，仍须加载首页并初始化窗口。 */
  onWindowStageRestore(windowStage: window.WindowStage): void {
    this.onWindowStageCreate(windowStage);
  }

  onDestroy(): void {
    Toast.release();
    Keyboard.release();
    safeArea.detach();
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }
}
