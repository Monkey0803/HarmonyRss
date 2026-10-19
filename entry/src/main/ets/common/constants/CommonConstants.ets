/*
 * CommonConstants.ets — 应用级通用逻辑常量。
 *
 * 纯逻辑常量（超时、分页、默认下标等）集中在这里；随环境变化的颜色 / 文本 / 尺寸
 * 一律走 resources（color.json / string.json / float.json）。
 */
export class CommonConstants {
  /** 应用启动时的默认页签下标。 */
  static readonly DEFAULT_TAB_INDEX: number = 0;
  /** 标题栏随内容滚动时，开始隐藏标题栏的滚动距离阈值（vp）——行为参数，不是视觉尺寸。 */
  static readonly TITLE_HIDE_OFFSET_VP: number = 10;
  /** HDS 紧凑标题栏（MINI）高度（vp）——HDS 规范固定值，用于透明标题栏下的首屏顶部占位。 */
  static readonly TITLE_BAR_HEIGHT_VP: number = 56;
  /** HDS 悬浮页签栏 / 操作栏高度（vp）——HDS 规范固定值，用于给它留出页面条带高度。 */
  static readonly TAB_BAR_HEIGHT_VP: number = 56;
  /** 悬浮页签栏上 miniBar（添加订阅源入口）宽度（vp）——圆角胶囊，够一个图标落位。 */
  static readonly MINI_BAR_WIDTH_VP: number = 64;
  /** 悬浮操作栏两侧留白（vp）：与首页悬浮页签栏的贴边距离一致。 */
  static readonly BAR_SIDE_MARGIN_VP: number = 16;
  /** 给「整栏跟手」预留的左右侧移余量（vp）：栏若贴满两侧就没有可平移到对侧的余量。 */
  static readonly BAR_HANDEDNESS_ROOM_VP: number = 48;
  /** 标题栏沉浸光感材质的渐显滚动距离（vp）：内容滚过该距离后材质完全生效——行为参数。 */
  static readonly TITLE_MATERIAL_FADE_VP: number = 24;
  /** App logo 在设置页预览瓦片中的边长（vp）。 */
  static readonly LOGO_TILE_SIZE: number = 46;
  /** App logo 预览瓦片圆角（vp）。 */
  static readonly LOGO_TILE_RADIUS: number = 14;
  /** App logo 在首页品牌行的边长（vp）。 */
  static readonly LOGO_BRAND_SIZE: number = 26;
  /** App logo 在首页品牌行的圆角（vp）。 */
  static readonly LOGO_BRAND_RADIUS: number = 8;
  /** 目的页入场转场时长（ms）：自右滑入 + 淡入。 */
  static readonly NAV_ENTER_DURATION_MS: number = 320;
  /** 目的页出场（pop）转场时长（ms）：向右滑出 + 淡出，略快于入场。 */
  static readonly NAV_EXIT_DURATION_MS: number = 260;
}
