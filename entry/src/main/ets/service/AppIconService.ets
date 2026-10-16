/*
 * AppIconService.ets — 桌面图标（应用图标）动态切换。
 *
 * 通过 AppGallery Kit 的 appInfoManager 切换系统桌面上的动态图标：图标素材由 AGC
 * 「图标管理服务」配置，应用侧按 iconId 选择。约束：应用必须已上架 AppGallery 且配置了
 * 动态图标；本地调试 / 未上架时会失败，这里统一 try/catch 返回 false，交由界面提示，
 * 不影响应用内 logo 的切换与持久化（整个流程优雅降级）。
 */

import { appInfoManager } from '@kit.AppGalleryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'AppIconService';
/** AGC 动态图标 id 前缀：与后台配置的图标 id 对应。 */
const ICON_ID_PREFIX: string = 'harmonyrss_';

export class AppIconService {
  /** 本机是否具备 AppGallery 动态图标能力。 */
  isSupported(): boolean {
    return canIUse('SystemCapability.AppGalleryService.AppInfoManager');
  }

  private iconIdFor(kind: string): string {
    return ICON_ID_PREFIX + kind;
  }

  /**
   * 把系统桌面图标切换为指定 logo 变体。
   * 返回是否真正切换成功；失败（未上架 / 未配置 / 能力缺失）时返回 false。
   */
  async selectDynamicIcon(kind: string): Promise<boolean> {
    if (!this.isSupported()) {
      return false;
    }
    try {
      await appInfoManager.selectDynamicIcon(this.iconIdFor(kind));
      hilog.info(DOMAIN, TAG, 'dynamic icon selected: %{public}s', kind);
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'selectDynamicIcon failed, code: %{public}d', err.code);
      return false;
    }
  }
}

export const appIconService: AppIconService = new AppIconService();
