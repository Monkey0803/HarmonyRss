/*
 * ThemeColorOptions.ets — 预设主题色表。
 *
 * 预设只用于「可点击的色板 + 文案」，持久化仍然只存 #RRGGBB：
 * 用户选自定义色后自然不属于任何预设，设置行显示色值即可。
 */

import { ThemeColorId } from '../common/constants/SettingsConstants';

/** 一个预设主题色。 */
export class ThemeColorPreset {
  readonly id: string;
  readonly hex: string;
  readonly label: Resource;

  constructor(id: string, hex: string, label: Resource) {
    this.id = id;
    this.hex = hex;
    this.label = label;
  }
}

/** 六个预设色：蓝 / 青 / 绿 / 橙 / 紫 / 粉。 */
export const THEME_COLOR_PRESETS: ThemeColorPreset[] = [
  new ThemeColorPreset(ThemeColorId.BLUE, '#0A59F7', $r('app.string.theme_color_blue')),
  new ThemeColorPreset(ThemeColorId.CYAN, '#0FA3A3', $r('app.string.theme_color_cyan')),
  new ThemeColorPreset(ThemeColorId.GREEN, '#2E9E4F', $r('app.string.theme_color_green')),
  new ThemeColorPreset(ThemeColorId.ORANGE, '#E86A17', $r('app.string.theme_color_orange')),
  new ThemeColorPreset(ThemeColorId.PURPLE, '#7A5AF8', $r('app.string.theme_color_purple')),
  new ThemeColorPreset(ThemeColorId.PINK, '#D94A86', $r('app.string.theme_color_pink'))
];

/** 色值对应的预设；自定义色返回 undefined。 */
export function presetOf(hex: string): ThemeColorPreset | undefined {
  const value: string = hex.trim().toUpperCase();
  for (let i = 0; i < THEME_COLOR_PRESETS.length; i += 1) {
    if (THEME_COLOR_PRESETS[i].hex.toUpperCase() === value) {
      return THEME_COLOR_PRESETS[i];
    }
  }
  return undefined;
}

/** 是否命中某个预设。 */
export function isPresetThemeColor(hex: string): boolean {
  return presetOf(hex) !== undefined;
}

/** 设置行展示文案：预设名或色值。 */
export function themeColorLabelOf(hex: string): ResourceStr {
  const preset: ThemeColorPreset | undefined = presetOf(hex);
  return preset !== undefined ? preset.label : hex.trim().toUpperCase();
}
