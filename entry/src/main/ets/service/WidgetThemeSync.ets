/*
 * WidgetThemeSync.ets — 主应用改主题色后定向刷新桌面卡片。
 *
 * 卡片进程无法观察 appSettings，只能吃 formBindingData；这里把当前色按深浅色
 * 收敛成 accent 后推给每张卡片。失败逐条吞掉，周期刷新（30 分钟）仍会兜底。
 */

import { formBindingData, formProvider } from '@kit.FormKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ThemeColorPrefs } from './ThemeColorPrefs';
import { WidgetFormStore } from './WidgetFormStore';
import { WidgetConstants } from '../common/constants/WidgetConstants';
import { ThemeColorMath, ThemeColorRoles } from '../common/utils/ThemeColorMath';

export class WidgetThemeSync {
  /** 把当前主题色推给所有已登记卡片。 */
  static async push(context: common.Context): Promise<void> {
    const ids: string[] = await WidgetFormStore.list(context);
    if (ids.length === 0) {
      return;
    }
    const themeColor: string = await ThemeColorPrefs.read(context);
    const isDark: boolean =
      context.resourceManager.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK;
    const roles: ThemeColorRoles = ThemeColorMath.roles(themeColor, isDark);
    const data: Record<string, string> = { 'themeAccent': roles.accent };
    for (let i = 0; i < ids.length; i += 1) {
      try {
        await formProvider.updateForm(ids[i], formBindingData.createFormBindingData(data));
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        console.error('WidgetThemeSync.updateForm failed: ' + error.code.toString());
      }
    }
  }
}
