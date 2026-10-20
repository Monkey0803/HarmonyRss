/*
 * SettingsOptions.ets — 设置项选项表（ChoiceSet）。
 *
 * 每一项只存**语义 id**（来自 common/constants/SettingsConstants 的 enum，不是枚举数值）：
 * 状态文件可读，SDK 枚举重排也不会错位；读到旧值 / 脏值统一退回默认项。控件（下拉菜单）只认 label。
 */

import { ArchiveRule, ListDensity, ListRowLayout, SummaryLines, ThemeMode, AppLanguage, MaterialKind, MaterialGrade, BackgroundKind, LogoKind, AutoRefreshInterval, ReaderFontSize, ReaderLineHeight, ReaderFontFamily, ReaderWidth, ReaderAlign, ReaderTheme } from '../common/constants/SettingsConstants';

/** 一个可选项：语义 id + 展示文案。 */
export class ChoiceOption {
  readonly id: string;
  readonly label: ResourceStr;

  constructor(id: string, label: ResourceStr) {
    this.id = id;
    this.label = label;
  }
}

/** 一张选项表：选项 + 默认项 + 归一 / 查下标 / 取文案。 */
export class ChoiceSet {
  readonly options: ChoiceOption[];
  readonly defaultValue: string;

  constructor(options: ChoiceOption[], defaultValue: string) {
    this.options = options;
    this.defaultValue = defaultValue;
  }

  /** 语义 id 在表里的下标；未知 id 返回默认项下标。 */
  indexOf(id: string): number {
    for (let i = 0; i < this.options.length; i += 1) {
      if (this.options[i].id === id) {
        return i;
      }
    }
    return this.indexOf(this.defaultValue);
  }

  /** 下标对应文案；越界退回默认项文案。 */
  labelAtIndex(index: number): ResourceStr {
    const safe: number = (index >= 0 && index < this.options.length) ? index : 0;
    return this.options[safe].label;
  }

  /** 语义 id 归一：认得出就保留，认不出退回默认项。 */
  normalize(id: string): string {
    for (let i = 0; i < this.options.length; i += 1) {
      if (this.options[i].id === id) {
        return id;
      }
    }
    return this.defaultValue;
  }

  /** 当前 id 对应的文案。 */
  labelOf(id: string): ResourceStr {
    return this.labelAtIndex(this.indexOf(id));
  }
}

/** 主题：跟随系统 / 浅色 / 深色。 */
export const THEME_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(ThemeMode.SYSTEM, $r('app.string.opt_follow_system')),
  new ChoiceOption(ThemeMode.LIGHT, $r('app.string.opt_light')),
  new ChoiceOption(ThemeMode.DARK, $r('app.string.opt_dark'))
], ThemeMode.SYSTEM);

/** 语言：跟随系统 / 简体中文 / 英语。 */
export const LANGUAGE_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(AppLanguage.SYSTEM, $r('app.string.opt_follow_system')),
  new ChoiceOption(AppLanguage.ZH, $r('app.string.opt_chinese')),
  new ChoiceOption(AppLanguage.EN, $r('app.string.opt_english'))
], AppLanguage.SYSTEM);

/** 材质类型：自适应 / 沉浸式 / 无材质效果（对应 hdsMaterial.MaterialType）。 */
export const MATERIAL_TYPE_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(MaterialKind.ADAPTIVE, $r('app.string.opt_material_adaptive')),
  new ChoiceOption(MaterialKind.IMMERSIVE, $r('app.string.opt_material_immersive')),
  new ChoiceOption(MaterialKind.NONE, $r('app.string.opt_material_none'))
], MaterialKind.ADAPTIVE);

/** 沉浸光感材质：四档（对应 hdsMaterial.MaterialLevel）。 */
export const MATERIAL_LEVEL_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(MaterialGrade.EXQUISITE, $r('app.string.opt_level_exquisite')),
  new ChoiceOption(MaterialGrade.GENTLE, $r('app.string.opt_level_gentle')),
  new ChoiceOption(MaterialGrade.SMOOTH, $r('app.string.opt_level_smooth')),
  new ChoiceOption(MaterialGrade.ADAPTIVE, $r('app.string.opt_level_adaptive'))
], MaterialGrade.ADAPTIVE);

/** 全局背景图：默认图 / 极光 / 暮色 / 自定义（相册图片）/ 关闭。 */
export const BACKGROUND_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(BackgroundKind.DEFAULT, $r('app.string.opt_bg_default')),
  new ChoiceOption(BackgroundKind.AURORA, $r('app.string.opt_bg_aurora')),
  new ChoiceOption(BackgroundKind.SUNSET, $r('app.string.opt_bg_sunset')),
  new ChoiceOption(BackgroundKind.CUSTOM, $r('app.string.opt_bg_custom')),
  new ChoiceOption(BackgroundKind.NONE, $r('app.string.opt_bg_none'))
], BackgroundKind.DEFAULT);

/** App logo：经典 / 极光 / 暮色 / 墨黑。 */
export const LOGO_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(LogoKind.CLASSIC, $r('app.string.logo_classic')),
  new ChoiceOption(LogoKind.AURORA, $r('app.string.logo_aurora')),
  new ChoiceOption(LogoKind.SUNSET, $r('app.string.logo_sunset')),
  new ChoiceOption(LogoKind.MONO, $r('app.string.logo_mono'))
], LogoKind.CLASSIC);

/** 自动刷新间隔：关闭 / 15 分钟 / 30 分钟 / 1 小时。 */
export const AUTO_REFRESH_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(AutoRefreshInterval.OFF, $r('app.string.opt_refresh_off')),
  new ChoiceOption(AutoRefreshInterval.MIN_15, $r('app.string.opt_refresh_15')),
  new ChoiceOption(AutoRefreshInterval.MIN_30, $r('app.string.opt_refresh_30')),
  new ChoiceOption(AutoRefreshInterval.MIN_60, $r('app.string.opt_refresh_60'))
], AutoRefreshInterval.OFF);

/** 列表行样式：纯文字 / 缩略图 / 大图卡片。 */
export const ROW_LAYOUT_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(ListRowLayout.TEXT, $r('app.string.opt_layout_text')),
  new ChoiceOption(ListRowLayout.THUMB, $r('app.string.opt_layout_thumb')),
  new ChoiceOption(ListRowLayout.CARD, $r('app.string.opt_layout_card'))
], ListRowLayout.THUMB);

/** 摘要行数：1 / 2 / 3。 */
export const SUMMARY_LINES_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(SummaryLines.ONE, $r('app.string.opt_lines_1')),
  new ChoiceOption(SummaryLines.TWO, $r('app.string.opt_lines_2')),
  new ChoiceOption(SummaryLines.THREE, $r('app.string.opt_lines_3'))
], SummaryLines.TWO);

/** 列表密度：紧凑 / 标准 / 宽松。 */
export const LIST_DENSITY_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(ListDensity.COMPACT, $r('app.string.opt_density_compact')),
  new ChoiceOption(ListDensity.STANDARD, $r('app.string.opt_density_standard')),
  new ChoiceOption(ListDensity.RELAXED, $r('app.string.opt_density_relaxed'))
], ListDensity.STANDARD);

/** 归档规则：已读且超过 N 天不进主列表。 */
export const ARCHIVE_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(ArchiveRule.OFF, $r('app.string.opt_archive_off')),
  new ChoiceOption(ArchiveRule.DAYS_7, $r('app.string.opt_archive_7')),
  new ChoiceOption(ArchiveRule.DAYS_14, $r('app.string.opt_archive_14')),
  new ChoiceOption(ArchiveRule.DAYS_30, $r('app.string.opt_archive_30')),
  new ChoiceOption(ArchiveRule.DAYS_90, $r('app.string.opt_archive_90'))
], ArchiveRule.DAYS_30);

/** 正文字号：小 / 中 / 大。 */
export const READER_FONT_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(ReaderFontSize.SMALL, $r('app.string.opt_font_small')),
  new ChoiceOption(ReaderFontSize.MEDIUM, $r('app.string.opt_font_medium')),
  new ChoiceOption(ReaderFontSize.LARGE, $r('app.string.opt_font_large'))
], ReaderFontSize.MEDIUM);

/** 正文行距：紧凑 / 标准 / 宽松。 */
export const READER_LINE_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(ReaderLineHeight.COMPACT, $r('app.string.opt_line_compact')),
  new ChoiceOption(ReaderLineHeight.NORMAL, $r('app.string.opt_line_normal')),
  new ChoiceOption(ReaderLineHeight.LOOSE, $r('app.string.opt_line_loose'))
], ReaderLineHeight.NORMAL);

/** 正文字体：系统默认 / 衬线 / 无衬线。 */
export const READER_FAMILY_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(ReaderFontFamily.SYSTEM, $r('app.string.opt_family_system')),
  new ChoiceOption(ReaderFontFamily.SERIF, $r('app.string.opt_family_serif')),
  new ChoiceOption(ReaderFontFamily.SANS, $r('app.string.opt_family_sans'))
], ReaderFontFamily.SYSTEM);

/** 阅读栏宽：窄 / 标准 / 宽。 */
export const READER_WIDTH_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(ReaderWidth.NARROW, $r('app.string.opt_width_narrow')),
  new ChoiceOption(ReaderWidth.STANDARD, $r('app.string.opt_width_standard')),
  new ChoiceOption(ReaderWidth.WIDE, $r('app.string.opt_width_wide'))
], ReaderWidth.STANDARD);

/** 正文对齐：左对齐 / 两端对齐。 */
export const READER_ALIGN_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(ReaderAlign.LEFT, $r('app.string.opt_align_left')),
  new ChoiceOption(ReaderAlign.JUSTIFY, $r('app.string.opt_align_justify'))
], ReaderAlign.LEFT);

/** 阅读主题：跟随系统 / 浅色 / 护眼 / 暗色。 */
export const READER_THEME_OPTIONS: ChoiceSet = new ChoiceSet([
  new ChoiceOption(ReaderTheme.SYSTEM, $r('app.string.opt_reader_theme_system')),
  new ChoiceOption(ReaderTheme.LIGHT, $r('app.string.opt_reader_theme_light')),
  new ChoiceOption(ReaderTheme.SEPIA, $r('app.string.opt_reader_theme_sepia')),
  new ChoiceOption(ReaderTheme.DARK, $r('app.string.opt_reader_theme_dark'))
], ReaderTheme.SYSTEM);
