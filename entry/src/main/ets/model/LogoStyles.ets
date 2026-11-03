/*
 * LogoStyles.ets — App logo 的配色方案表。
 *
 * 每个 logo 变体只描述「背景渐变的起止色 + 图形标记色」；几何形状（RSS 波纹 + 文章行）
 * 固定在 common/components/AppLogo.ets，新增一套配色即可得到一个新 logo。
 *
 * 配色现在由主题色派生：保留四款变体的形状 / 风格差异，但色相跟随用户选择的主题色。
 * 这里用十六进制字符串而不是 $r 资源：标记由 Canvas 绘制，fillStyle / strokeStyle
 * 只接受字符串或渐变对象，不接受 Resource。
 */

import { LogoKind } from '../common/constants/SettingsConstants';
import { ThemeColorMath, ThemeColorRoles } from '../common/utils/ThemeColorMath';

/** 一个 logo 变体的配色：渐变起止色 + 前景标记色。 */
export class LogoStyle {
  readonly colorStart: string;
  readonly colorEnd: string;
  readonly markColor: string;

  constructor(colorStart: string, colorEnd: string, markColor: string) {
    this.colorStart = colorStart;
    this.colorEnd = colorEnd;
    this.markColor = markColor;
  }
}

/** 白色标记在渐变两端都要保持可读：低于目标对比度时自动加深。 */
function readableForWhite(hex: string): string {
  return ThemeColorMath.ensureWhiteText(hex, 3.0);
}

/**
 * 语义 id 对应的配色；未知 id 退回经典配色。
 * themeColor 为 #RRGGBB；isDark 决定 accent 的明度方向。
 */
export function logoStyleOf(id: string, themeColor: string, isDark: boolean): LogoStyle {
  const roles: ThemeColorRoles = ThemeColorMath.roles(themeColor, isDark);
  const fill: string = roles.fill;
  if (id === LogoKind.AURORA) {
    return new LogoStyle(
      readableForWhite(ThemeColorMath.hueShift(fill, 20)),
      readableForWhite(ThemeColorMath.hueShift(fill, -45)),
      '#FFFFFF'
    );
  }
  if (id === LogoKind.SUNSET) {
    return new LogoStyle(
      readableForWhite(ThemeColorMath.hueShift(fill, -35)),
      readableForWhite(ThemeColorMath.hueShift(fill, 55)),
      '#FFFFFF'
    );
  }
  if (id === LogoKind.MONO) {
    return new LogoStyle('#1B1D23', '#343A46', ThemeColorMath.monoMark(roles.accent));
  }
  return new LogoStyle(
    fill,
    readableForWhite(ThemeColorMath.lighten(fill, 0.16)),
    '#FFFFFF'
  );
}
