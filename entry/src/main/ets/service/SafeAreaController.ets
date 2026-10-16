/*
 * SafeAreaController.ets — 底部避让尺寸（Model 层：屏蔽窗口能力）。
 *
 * 应用在 EntryAbility 里调用了 setWindowLayoutFullScreen(true)，布局不做系统栏避让。
 * 顶部由 HDS 标题栏的 enableComponentSafeArea / avoidLayoutSafeArea 处理，界面无需自己估算；
 * 这里只提供底部需要的尺寸：
 *   - contentBottomInsetVp：可滚动内容底部预留量（= 悬浮页签栏避让高度 + 系统导航条高度）；
 *   - bottomInsetVp：系统导航条高度，用于无页签栏的 NavDestination 页面底部内缩。
 *
 * 单位统一换算成 vp，方便直接用于布局；旋转 / 分屏 / 折叠时由 avoidAreaChange 刷新。
 */

import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'SafeAreaController';

@ObservedV2
export class SafeAreaController {
  /** 顶部系统状态栏高度（vp）。 */
  @Trace topInsetVp: number = 0;
  /** 底部系统导航条高度（vp）。 */
  @Trace bottomInsetVp: number = 0;
  /** 可滚动内容底部预留量（vp）= 悬浮页签栏避让高度 + 系统导航条高度。 */
  @Trace contentBottomInsetVp: number = 0;

  private mainWindow: window.Window | undefined = undefined;
  private tabClearanceVp: number = 0;

  /** 绑定主窗口：读一次尺寸，并监听旋转 / 分屏 / 折叠带来的变化。 */
  attach(context: common.Context, mainWindow: window.Window): void {
    this.tabClearanceVp = this.readFloat(context, $r('app.float.tab_clearance'));
    this.mainWindow = mainWindow;
    this.refresh();
    try {
      mainWindow.on('avoidAreaChange', () => {
        this.refresh();
      });
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'avoidAreaChange listen failed: %{public}d', error.code);
    }
  }

  /** 解绑监听（窗口销毁时调用）。 */
  detach(): void {
    const mainWindow: window.Window | undefined = this.mainWindow;
    if (mainWindow === undefined) {
      return;
    }
    try {
      mainWindow.off('avoidAreaChange');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'avoidAreaChange off failed: %{public}d', error.code);
    }
    this.mainWindow = undefined;
  }

  /** 界面尺寸不硬编码在 .ets 里：从 resources 的 float 读取。 */
  private readFloat(context: common.Context, res: Resource): number {
    try {
      return context.resourceManager.getNumber(res.id);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'read float failed: %{public}d', error.code);
      return 0;
    }
  }

  private refresh(): void {
    const mainWindow: window.Window | undefined = this.mainWindow;
    if (mainWindow === undefined) {
      return;
    }
    try {
      const statusBar: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.topInsetVp = statusBar.visible
        ? mainWindow.getUIContext().px2vp(statusBar.topRect.height)
        : 0;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'getWindowAvoidArea(TYPE_SYSTEM) failed: %{public}d', error.code);
      this.topInsetVp = 0;
    }
    try {
      const indicator: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      // 用窗口自己的 UIContext 做 px→vp 换算：全局 px2vp 已废弃。
      this.bottomInsetVp = indicator.visible
        ? mainWindow.getUIContext().px2vp(indicator.bottomRect.height)
        : 0;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'getWindowAvoidArea(TYPE_NAVIGATION_INDICATOR) failed: %{public}d', error.code);
      this.bottomInsetVp = 0;
    }
    this.contentBottomInsetVp = this.tabClearanceVp + this.bottomInsetVp;
  }
}

/** 全局唯一实例。 */
export const safeArea: SafeAreaController = new SafeAreaController();
