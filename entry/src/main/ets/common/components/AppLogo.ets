/*
 * AppLogo.ets — App 图形标志。底为圆角块 + 品牌渐变，标记用 Canvas 绘制。
 *
 * 功能母题：**RSS 订阅 + 阅读**。标记由两部分组成，直接表达 App 干的事：
 *   1) RSS 波纹（圆点 + 两道同心 1/4 圆弧）—— 订阅 / 信息源；
 *   2) 两条文章行（圆角短横，长短不一）—— 阅读 / 文章列表。
 * 四款变体只在配色、外轮廓（圆 / 方）与描边风格（实心 / 线框）上区分，保持同一家族形象。
 *
 * 为什么用 Canvas 而不是 Shape/Path：Shape 的 viewPort 与 Path.commands 坐标单位在真机 /
 * 模拟器上表现不一致（图形会被画成实际尺寸的 1/3 并贴在左上角），调试成本高；Canvas 的
 * CanvasRenderingContext2D 统一按 vp 坐标绘制，尺寸可预期。Canvas 只画标记，底色仍用
 * Stack 的 linearGradient，颜色见 model/LogoStyles。
 */

import { LogoStyle, logoStyleOf } from '../../model/LogoStyles';
import { LogoKind } from '../constants/SettingsConstants';

/** 设计稿为 100×100 单位，绘制时按 logoSize/100 缩放到 vp。 */
const DESIGN: number = 100;

@ComponentV2
export struct AppLogo {
  /** logo 变体语义 id（LogoKind）。 */
  @Param logoKind: string = LogoKind.CLASSIC;
  /** 外框边长（vp）。 */
  @Param logoSize: number = 44;
  /** 外框圆角半径（vp）；极光变体强制为圆形，忽略此值。 */
  @Param cornerRadius: number = 12;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  /** logoKind 变化（如首页品牌行切换）时重绘标记。 */
  @Monitor('logoKind')
  onLogoKindChange(): void {
    this.drawMark();
  }

  private style(): LogoStyle {
    return logoStyleOf(this.logoKind);
  }

  /** 极光变体是圆形，其余为圆角方块。 */
  private radius(): number {
    return this.logoKind === LogoKind.AURORA ? this.logoSize / 2 : this.cornerRadius;
  }

  /** 线框风格（墨黑）：描边更细。 */
  private isOutline(): boolean {
    return this.logoKind === LogoKind.MONO;
  }

  /**
   * 绘制标记（vp 坐标）：RSS 波纹在上、文章行在下，整体居中。
   * 波纹圆心 (32,50)：圆点 r=6，两道圆弧 r=16 / r=26，从正上方扫到正右方。
   */
  private drawMark(): void {
    const s: number = this.logoSize;
    const k: number = s / DESIGN;
    const ctx: CanvasRenderingContext2D = this.context;
    const mark: string = this.style().markColor;
    const arcWidth: number = s * (this.isOutline() ? 0.07 : 0.09);
    const lineWidth: number = s * (this.isOutline() ? 0.06 : 0.08);

    ctx.clearRect(0, 0, s, s);
    ctx.strokeStyle = mark;
    ctx.fillStyle = mark;
    ctx.lineCap = 'round';

    // RSS 圆弧（外弧 + 内弧）。
    ctx.lineWidth = arcWidth;
    ctx.beginPath();
    ctx.arc(32 * k, 50 * k, 26 * k, -Math.PI / 2, 0);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(32 * k, 50 * k, 16 * k, -Math.PI / 2, 0);
    ctx.stroke();

    // RSS 圆点。
    ctx.beginPath();
    ctx.arc(32 * k, 50 * k, 6 * k, 0, Math.PI * 2);
    ctx.fill();

    // 文章行（阅读）：一长一短两条圆角横线。
    ctx.lineWidth = lineWidth;
    ctx.beginPath();
    ctx.moveTo(30 * k, 68 * k);
    ctx.lineTo(74 * k, 68 * k);
    ctx.moveTo(30 * k, 80 * k);
    ctx.lineTo(62 * k, 80 * k);
    ctx.stroke();
  }

  build() {
    Stack() {
      Canvas(this.context)
        .width(this.logoSize)
        .height(this.logoSize)
        .onReady(() => {
          this.drawMark();
        })
    }
    .width(this.logoSize)
    .height(this.logoSize)
    .borderRadius(this.radius())
    .clip(true)
    .backgroundColor(this.style().colorStart)
    .linearGradient({
      angle: 135,
      colors: [[this.style().colorStart, 0.0], [this.style().colorEnd, 1.0]]
    })
  }
}
