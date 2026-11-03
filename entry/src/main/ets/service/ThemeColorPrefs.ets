/*
 * ThemeColorPrefs.ets — 轻量读取偏好库里的主题色（供卡片进程使用）。
 *
 * 卡片进程不应该 import SettingsStore（会带进备份 / 同步等一大串依赖），
 * 这里只读一个键并归一，保持卡片侧依赖最小。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';
import { DEFAULT_THEME_COLOR } from '../common/constants/SettingsConstants';
import { ThemeColorMath } from '../common/utils/ThemeColorMath';

export class ThemeColorPrefs {
  /** 读取当前主题色；读不到 / 脏值一律回退默认品牌蓝。 */
  static async read(context: common.Context): Promise<string> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      const raw: string =
        store.getSync(PreferencesConstants.KEY_THEME_COLOR, DEFAULT_THEME_COLOR) as string;
      return ThemeColorMath.normalize(raw, DEFAULT_THEME_COLOR);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('ThemeColorPrefs.read failed: ' + error.code.toString());
      return DEFAULT_THEME_COLOR;
    }
  }
}
