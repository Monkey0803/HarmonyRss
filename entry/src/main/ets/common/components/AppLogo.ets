/*
 * AppLogo.ets — App 图形标志。底为圆角块 + 品牌渐变，标记用 Canvas 绘制。
 *
 * 功能母题：**RSS 订阅 + 阅读**。与商店及桌面图标共用「RSS 波纹 + 展开的书页」。
 * 四款变体仅更换配色，统一圆角与标记形状，和桌面图标对应。
 *
 * 为什么用 Canvas 而不是 Shape/Path：Shape 的 viewPort 与 Path.commands 坐标单位在真机 /
 * 模拟器上表现不一致（图形会被画成实际尺寸的 1/3 并贴在左上角），调试成本高；Canvas 的
 * CanvasRenderingContext2D 统一按 vp 坐标绘制，尺寸可预期。Canvas 只画标记，底色仍用
 * Stack 的 linearGradient，颜色见 model/LogoStyles。
 */

import { LogoStyle, logoStyleOf } from '../../model/LogoStyles';
import { LogoKind } from '../constants/SettingsConstants';

/** 与 brand/source-icon.svg 共用 1024×1024 坐标。 */
const DESIGN: number = 1024;

@ComponentV2
export struct AppLogo {
  /** logo 变体语义 id（LogoKind）。 */
  @Param logoKind: string = LogoKind.CLASSIC;
  /** 外框边长（vp）。 */
  @Param logoSize: number = 44;
  /** 外框圆角半径（vp），四款变体一致。 */
  @Param cornerRadius: number = 12;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  /** Canvas 是否已就绪；未就绪时只等 onReady 画一次。 */
  private canvasReady: boolean = false;

  /** 变体变化时重绘标记。 */
  @Monitor('logoKind')
  onVisualChange(): void {
    if (this.canvasReady) {
      this.drawMark();
    }
  }

  private style(): LogoStyle {
    return logoStyleOf(this.logoKind);
  }

  /**
   * 绘制标记（vp 坐标）：上方是订阅波纹，下方是打开的书页。
   */
  private drawMark(): void {
    const s: number = this.logoSize;
    const k: number = s / DESIGN;
    const ctx: CanvasRenderingContext2D = this.context;
    const mark: string = this.style().markColor;
    const arcWidth: number = s * 0.037;

    ctx.clearRect(0, 0, s, s);
    ctx.strokeStyle = mark;
    ctx.fillStyle = mark;
    ctx.lineCap = 'butt';

    // RSS 圆弧（外弧 + 内弧）。
    ctx.lineWidth = arcWidth;
    ctx.beginPath();
    ctx.arc(370 * k, 407 * k, 200 * k, -Math.PI / 2, 0);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(370 * k, 407 * k, 110 * k, -Math.PI / 2, 0);
    ctx.stroke();

    // RSS 圆点。
    ctx.beginPath();
    ctx.arc(370 * k, 407 * k, 29 * k, 0, Math.PI * 2);
    ctx.fill();

    // 翻开的两页书，中间留白形成书脊。
    ctx.beginPath();
    ctx.moveTo(234 * k, 550 * k);
    ctx.quadraticCurveTo(366 * k, 515 * k, 497 * k, 575 * k);
    ctx.lineTo(497 * k, 759 * k);
    ctx.quadraticCurveTo(365 * k, 697 * k, 234 * k, 734 * k);
    ctx.closePath();
    ctx.fill();
    ctx.beginPath();
    ctx.moveTo(527 * k, 575 * k);
    ctx.quadraticCurveTo(658 * k, 515 * k, 790 * k, 550 * k);
    ctx.lineTo(790 * k, 734 * k);
    ctx.quadraticCurveTo(659 * k, 697 * k, 527 * k, 759 * k);
    ctx.closePath();
    ctx.fill();
  }

  build() {
    Stack() {
      Canvas(this.context)
        .width(this.logoSize)
        .height(this.logoSize)
        .onReady(() => {
          this.canvasReady = true;
          this.drawMark();
        })
    }
    .width(this.logoSize)
    .height(this.logoSize)
    .borderRadius(this.cornerRadius)
    .clip(true)
    .backgroundColor(this.style().colorStart)
    .linearGradient({
      angle: 135,
      colors: [[this.style().colorStart, 0.0], [this.style().colorEnd, 1.0]]
    })
  }
}
