/*
 * LogoStyles.ets — App logo 的配色方案表。
 *
 * 每个 logo 变体只描述「背景渐变的起止色 + 图形标记色」；几何形状（RSS 波纹 + 文章行）
 * 固定在 common/components/AppLogo.ets，新增一套配色即可得到一个新 logo。
 *
 * 这里用十六进制字符串而不是 $r 资源：标记由 Canvas 绘制，CanvasRenderingContext2D 的
 * fillStyle / strokeStyle 只接受字符串或渐变对象，不接受 Resource；而 logo 底是实色渐变、
 * 不随深浅色主题变化，直接用色值更简单也更可靠。
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

const CLASSIC: LogoStyle = new LogoStyle('#0A59F7', '#4A9BFF', '#FFFFFF');
const AURORA: LogoStyle = new LogoStyle('#12B5A5', '#2E6BFF', '#FFFFFF');
const SUNSET: LogoStyle = new LogoStyle('#FF7A45', '#FF3B80', '#FFFFFF');
const MONO: LogoStyle = new LogoStyle('#1B1D23', '#343A46', '#6FA8FF');

/** 语义 id 对应的配色；未知 id 退回经典配色。 */
export function logoStyleOf(id: string): LogoStyle {
  switch (id) {
    case LogoKind.AURORA:
      return AURORA;
    case LogoKind.SUNSET:
      return SUNSET;
    case LogoKind.MONO:
      return MONO;
    default:
      return CLASSIC;
  }
}
