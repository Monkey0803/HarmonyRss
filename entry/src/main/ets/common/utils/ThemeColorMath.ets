/*
 * ThemeColorMath.ets — 主题色纯计算（无 UI / 无设置状态依赖，可在单测直接调用）。
 *
 * 一套主题色对外只暴露三个 token：
 *   - accent：文字 / 图标 / 分割线，保证与页面底色有足够对比度；
 *   - fill：实心按钮 / 开关 / 徽标，保证白色文字可读；
 *   - tint：选中态浅底（#AARRGGBB）。
 *
 * 默认品牌蓝走「原资源值」特殊分支，保证不改主题色时视觉零变化；
 * 自定义色在 HSL 空间只调整明度，保留用户选择的色相与饱和度。
 */

import { DEFAULT_THEME_COLOR } from '../constants/SettingsConstants';

/** 浅色页面底色（白）。 */
const LIGHT_SURFACE: string = '#FFFFFF';
/** 深色卡片底色（与 resources/dark 的 hm_card_background 接近）。 */
const DARK_SURFACE: string = '#1E2128';
/** 墨黑 logo 的底色。 */
const MONO_SURFACE: string = '#1B1D23';
/** 正文 / 图标对比度目标。 */
const TEXT_CONTRAST: number = 4.5;

/** 一组主题色 token。 */
export class ThemeColorRoles {
  readonly accent: string;
  readonly fill: string;
  readonly tint: string;

  constructor(accent: string, fill: string, tint: string) {
    this.accent = accent;
    this.fill = fill;
    this.tint = tint;
  }
}

/** HSL 颜色（h: 0–360，s/l: 0–1）。 */
class HslColor {
  readonly h: number;
  readonly s: number;
  readonly l: number;

  constructor(h: number, s: number, l: number) {
    this.h = h;
    this.s = s;
    this.l = l;
  }
}

export class ThemeColorMath {
  /** 默认主题色：直接返回现有资源值，保持默认外观不变。 */
  private static legacyRoles(isDark: boolean): ThemeColorRoles {
    if (isDark) {
      return new ThemeColorRoles('#3F7CFF', '#3F7CFF', '#333F7CFF');
    }
    return new ThemeColorRoles('#0A59F7', '#0A59F7', '#1A0A59F7');
  }

  /** 归一化为 #RRGGBB；支持 #RGB / #RRGGBB / #AARRGGBB / rgb() / rgba()。 */
  static normalize(raw: string, fallback: string): string {
    const parsed: string = ThemeColorMath.parse(raw);
    if (parsed.length > 0) {
      return parsed;
    }
    const fallbackParsed: string = ThemeColorMath.parse(fallback);
    return fallbackParsed.length > 0 ? fallbackParsed : DEFAULT_THEME_COLOR;
  }

  /** 解析颜色；无法识别返回空串。 */
  private static parse(raw: string): string {
    const value: string = raw.trim().toUpperCase();
    if (value.length === 0) {
      return '';
    }
    if (value.startsWith('RGB')) {
      return ThemeColorMath.parseRgbFunction(value);
    }
    let hex: string = value.startsWith('#') ? value.substring(1) : value;
    // HarmonyOS 资源与 HDS 取色器可能返回 #AARRGGBB：忽略 alpha，取后 6 位。
    if (hex.length === 8) {
      hex = hex.substring(2);
    }
    if (hex.length === 3) {
      const r: string = hex.substring(0, 1);
      const g: string = hex.substring(1, 2);
      const b: string = hex.substring(2, 3);
      hex = r + r + g + g + b + b;
    }
    if (hex.length !== 6) {
      return '';
    }
    for (let i = 0; i < hex.length; i += 1) {
      const code: number = hex.charCodeAt(i);
      const digit: boolean = (code >= 48 && code <= 57) || (code >= 65 && code <= 70);
      if (!digit) {
        return '';
      }
    }
    return '#' + hex;
  }

  /** 解析 rgb(r,g,b) / rgba(r,g,b,a)。 */
  private static parseRgbFunction(value: string): string {
    const left: number = value.indexOf('(');
    const right: number = value.indexOf(')');
    if (left < 0 || right <= left) {
      return '';
    }
    const parts: string[] = value.substring(left + 1, right).split(',');
    if (parts.length < 3) {
      return '';
    }
    const r: number = ThemeColorMath.channelValue(parts[0]);
    const g: number = ThemeColorMath.channelValue(parts[1]);
    const b: number = ThemeColorMath.channelValue(parts[2]);
    if (r < 0 || g < 0 || b < 0) {
      return '';
    }
    return '#' + ThemeColorMath.hexChannel(r) + ThemeColorMath.hexChannel(g) + ThemeColorMath.hexChannel(b);
  }

  /** rgb 分量字符串 → 0–255；非法返回 -1。 */
  private static channelValue(raw: string): number {
    const text: string = raw.trim();
    if (text.length === 0) {
      return -1;
    }
    const value: number = Number(text);
    if (!Number.isFinite(value)) {
      return -1;
    }
    return Math.max(0, Math.min(255, Math.round(value)));
  }

  /** 0–255 → 两位十六进制。 */
  private static hexChannel(value: number): string {
    return Math.max(0, Math.min(255, value)).toString(16).padStart(2, '0').toUpperCase();
  }

  /** #RRGGBB → [r, g, b]。 */
  private static rgb(hex: string): number[] {
    const value: string = hex.startsWith('#') ? hex.substring(1) : hex;
    if (value.length !== 6) {
      return [0, 0, 0];
    }
    return [
      Number.parseInt(value.substring(0, 2), 16),
      Number.parseInt(value.substring(2, 4), 16),
      Number.parseInt(value.substring(4, 6), 16)
    ];
  }

  /** WCAG 相对亮度。 */
  private static luminance(hex: string): number {
    const values: number[] = ThemeColorMath.rgb(hex);
    const r: number = ThemeColorMath.linear(values[0] / 255);
    const g: number = ThemeColorMath.linear(values[1] / 255);
    const b: number = ThemeColorMath.linear(values[2] / 255);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  private static linear(value: number): number {
    return value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
  }

  /** 两色对比度（1–21）。 */
  static contrast(a: string, b: string): number {
    const first: number = ThemeColorMath.luminance(ThemeColorMath.normalize(a, DEFAULT_THEME_COLOR));
    const second: number = ThemeColorMath.luminance(ThemeColorMath.normalize(b, DEFAULT_THEME_COLOR));
    const high: number = Math.max(first, second);
    const low: number = Math.min(first, second);
    return (high + 0.05) / (low + 0.05);
  }

  /** RGB → HSL。 */
  private static rgbToHsl(hex: string): HslColor {
    const values: number[] = ThemeColorMath.rgb(hex);
    const r: number = values[0] / 255;
    const g: number = values[1] / 255;
    const b: number = values[2] / 255;
    let max: number = r;
    if (g > max) {
      max = g;
    }
    if (b > max) {
      max = b;
    }
    let min: number = r;
    if (g < min) {
      min = g;
    }
    if (b < min) {
      min = b;
    }
    const l: number = (max + min) / 2;
    if (max === min) {
      return new HslColor(0, 0, l);
    }
    const delta: number = max - min;
    const s: number = l > 0.5 ? delta / (2 - max - min) : delta / (max + min);
    let h: number = 0;
    if (max === r) {
      h = (g - b) / delta + (g < b ? 6 : 0);
    } else if (max === g) {
      h = (b - r) / delta + 2;
    } else {
      h = (r - g) / delta + 4;
    }
    return new HslColor(h * 60, s, l);
  }

  /** HSL → #RRGGBB。 */
  private static hslToHex(h: number, s: number, l: number): string {
    const hue: number = (((h % 360) + 360) % 360) / 360;
    let r: number = 0;
    let g: number = 0;
    let b: number = 0;
    if (s === 0) {
      r = l;
      g = l;
      b = l;
    } else {
      const q: number = l < 0.5 ? l * (1 + s) : l + s - l * s;
      const p: number = 2 * l - q;
      r = ThemeColorMath.hueToRgb(p, q, hue + 1 / 3);
      g = ThemeColorMath.hueToRgb(p, q, hue);
      b = ThemeColorMath.hueToRgb(p, q, hue - 1 / 3);
    }
    return '#' + ThemeColorMath.unitChannel(r) + ThemeColorMath.unitChannel(g) + ThemeColorMath.unitChannel(b);
  }

  private static hueToRgb(p: number, q: number, t: number): number {
    let value: number = t;
    if (value < 0) {
      value += 1;
    }
    if (value > 1) {
      value -= 1;
    }
    if (value < 1 / 6) {
      return p + (q - p) * 6 * value;
    }
    if (value < 1 / 2) {
      return q;
    }
    if (value < 2 / 3) {
      return p + (q - p) * (2 / 3 - value) * 6;
    }
    return p;
  }

  private static unitChannel(value: number): string {
    return ThemeColorMath.hexChannel(Math.round(Math.max(0, Math.min(1, value)) * 255));
  }

  /**
   * 调整明度直到与背景达到目标对比度。
   * lighten = true 时变亮（用于深色底），false 时变暗（用于浅色底）。
   */
  static ensureContrast(hex: string, background: string, ratio: number, lighten: boolean): string {
    const base: string = ThemeColorMath.normalize(hex, DEFAULT_THEME_COLOR);
    if (ThemeColorMath.contrast(base, background) >= ratio) {
      return base;
    }
    const hsl: HslColor = ThemeColorMath.rgbToHsl(base);
    let lightness: number = hsl.l;
    let current: string = base;
    for (let i = 0; i < 100; i += 1) {
      lightness = lighten ? Math.min(0.98, lightness + 0.01) : Math.max(0.02, lightness - 0.01);
      current = ThemeColorMath.hslToHex(hsl.h, hsl.s, lightness);
      if (ThemeColorMath.contrast(current, background) >= ratio) {
        return current;
      }
      if ((lighten && lightness >= 0.98) || (!lighten && lightness <= 0.02)) {
        return current;
      }
    }
    return current;
  }

  /** 保证目标色在白色文字下可读（用于实心填充）。 */
  static ensureWhiteText(hex: string, ratio: number): string {
    return ThemeColorMath.ensureContrast(hex, LIGHT_SURFACE, ratio, false);
  }

  /** 保证目标色在指定深色底上可读（用于墨黑 logo 标记）。 */
  static ensureOnDark(hex: string, background: string, ratio: number): string {
    return ThemeColorMath.ensureContrast(hex, background, ratio, true);
  }

  /** 叠加透明度，返回 #AARRGGBB（alpha 0–255）。 */
  static withAlpha(hex: string, alpha: number): string {
    const base: string = ThemeColorMath.normalize(hex, DEFAULT_THEME_COLOR);
    const value: number = Math.max(0, Math.min(255, Math.round(alpha)));
    return '#' + value.toString(16).padStart(2, '0').toUpperCase() + base.substring(1);
  }

  /** 明度增加 amount（0–1，可正可负）。 */
  static lighten(hex: string, amount: number): string {
    const base: string = ThemeColorMath.normalize(hex, DEFAULT_THEME_COLOR);
    const hsl: HslColor = ThemeColorMath.rgbToHsl(base);
    return ThemeColorMath.hslToHex(hsl.h, hsl.s, Math.max(0, Math.min(1, hsl.l + amount)));
  }

  /** 色相旋转 degrees（可为负）。 */
  static hueShift(hex: string, degrees: number): string {
    const base: string = ThemeColorMath.normalize(hex, DEFAULT_THEME_COLOR);
    const hsl: HslColor = ThemeColorMath.rgbToHsl(base);
    return ThemeColorMath.hslToHex(hsl.h + degrees, hsl.s, hsl.l);
  }

  /** 当前主题色 → 三个 token。 */
  static roles(hex: string, isDark: boolean): ThemeColorRoles {
    const base: string = ThemeColorMath.normalize(hex, DEFAULT_THEME_COLOR);
    if (base === DEFAULT_THEME_COLOR) {
      return ThemeColorMath.legacyRoles(isDark);
    }
    const surface: string = isDark ? DARK_SURFACE : LIGHT_SURFACE;
    const accent: string = ThemeColorMath.ensureContrast(base, surface, TEXT_CONTRAST, isDark);
    const fill: string = ThemeColorMath.ensureWhiteText(base, TEXT_CONTRAST);
    const tint: string = ThemeColorMath.withAlpha(fill, isDark ? 0x33 : 0x1A);
    return new ThemeColorRoles(accent, fill, tint);
  }

  /** 墨黑 logo 标记色：在深色底上可读。 */
  static monoMark(hex: string): string {
    return ThemeColorMath.ensureOnDark(hex, MONO_SURFACE, TEXT_CONTRAST);
  }
}
