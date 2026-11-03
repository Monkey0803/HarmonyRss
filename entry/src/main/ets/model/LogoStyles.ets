/*
 * LogoStyles.ets — App logo 的配色方案表。
 *
 * 每个 logo 变体只描述「背景渐变的起止色 + 图形标记色」；几何形状（RSS 波纹 + 书页）
 * 固定在 common/components/AppLogo.ets。
 *
 * 配色与 AppScope 的备选桌面图标固定对应，避免预览与最终图标不一致。
 * 这里用十六进制字符串而不是 $r 资源：标记由 Canvas 绘制，fillStyle / strokeStyle
 * 只接受字符串或渐变对象，不接受 Resource。
 */

import { LogoKind } from '../common/constants/SettingsConstants';

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

/** 语义 id 对应的固定配色；未知 id 退回经典配色。 */
export function logoStyleOf(id: string): LogoStyle {
  if (id === LogoKind.AURORA) {
    return new LogoStyle('#006A8E', '#786BE8', '#FFFFFF');
  }
  if (id === LogoKind.SUNSET) {
    return new LogoStyle('#B93569', '#F68B50', '#FFFFFF');
  }
  if (id === LogoKind.MONO) {
    return new LogoStyle('#20242C', '#454B58', '#FFFFFF');
  }
  return new LogoStyle('#0D4DC6', '#3A9DF9', '#FFFFFF');
}
