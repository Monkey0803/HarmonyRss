/*
 * ThemeController.ets — 主题（跟随系统 / 浅色 / 深色）。
 *
 * 跟随系统 = COLOR_MODE_NOT_SET；浅色 / 深色分别显式设定。颜色资源在
 * resources/{base,dark}/element/color.json，由平台自动切换。
 */

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeMode } from '../common/constants/SettingsConstants';
import { themePalette } from '../model/ThemePalette';

const DOMAIN: number = 0x0000;
const TAG: string = 'ThemeController';

export class ThemeController {
  /** setColorMode 标注可能抛异常；设置主题失败不应该影响其它启动流程，只记日志。 */
  static apply(context: common.Context, mode: string): void {
    try {
      const applicationContext: common.ApplicationContext = context.getApplicationContext();
      if (mode === ThemeMode.DARK) {
        applicationContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else if (mode === ThemeMode.LIGHT) {
        applicationContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else {
        applicationContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
      // 运行时颜色不走资源系统，深浅色由调色板自己维护：
      // 显式浅 / 深色直接写入；跟随系统先读当前配置，后续由 onConfigurationUpdate 校正。
      if (mode === ThemeMode.DARK) {
        themePalette.setDark(true);
      } else if (mode === ThemeMode.LIGHT) {
        themePalette.setDark(false);
      } else {
        const colorMode: resourceManager.ColorMode =
          context.resourceManager.getConfigurationSync().colorMode;
        themePalette.setDark(colorMode === resourceManager.ColorMode.DARK);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'setColorMode failed: %{public}d', error.code);
    }
  }
}
