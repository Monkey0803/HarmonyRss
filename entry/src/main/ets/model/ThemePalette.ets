/*
 * ThemePalette.ets — 运行时主题色调色板（ArkTS 状态管理 V2）。
 *
 * 组件在 build() / @Builder 中直接调用 accent() / fill() / tint() 即可：
 * getter 会读取 appSettings.themeColor（@Trace）与 isDark（@Trace），
 * 因此主题色或深浅色变化时，所有读过调色板的组件都会自动刷新。
 *
 * 计算结果按 (themeColor, isDark) 缓存，避免列表每行重复做 HSL 换算。
 */

import { DEFAULT_THEME_COLOR } from '../common/constants/SettingsConstants';
import { ThemeColorMath, ThemeColorRoles } from '../common/utils/ThemeColorMath';
import { appSettings } from './AppSettings';

@ObservedV2
export class ThemePalette {
  /** 当前是否深色模式；由 ThemeController / EntryAbility 维护。 */
  @Trace isDark: boolean = false;

  private cachedColor: string = '';
  private cachedDark: boolean = false;
  private cachedRoles: ThemeColorRoles = ThemeColorMath.roles(DEFAULT_THEME_COLOR, false);

  /** 当前主题色对应的三个 token；读取时建立观察关系。 */
  roles(): ThemeColorRoles {
    const color: string = appSettings.themeColor;
    const dark: boolean = this.isDark;
    if (color === this.cachedColor && dark === this.cachedDark) {
      return this.cachedRoles;
    }
    this.cachedColor = color;
    this.cachedDark = dark;
    this.cachedRoles = ThemeColorMath.roles(color, dark);
    return this.cachedRoles;
  }

  /** 文字 / 图标 / 分割线色。 */
  accent(): string {
    return this.roles().accent;
  }

  /** 实心按钮 / 开关 / 徽标填充色（白色文字可读）。 */
  fill(): string {
    return this.roles().fill;
  }

  /** 选中态浅底（#AARRGGBB）。 */
  tint(): string {
    return this.roles().tint;
  }

  /** 更新深浅色；值未变化时不触发刷新。 */
  setDark(value: boolean): void {
    if (this.isDark !== value) {
      this.isDark = value;
    }
  }
}

/** 全局唯一主题色调色板。 */
export const themePalette: ThemePalette = new ThemePalette();
