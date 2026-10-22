/*
 * SettingsConstants.ets — 设置项的语义 id（一组相关常量，用 enum 管理）。
 *
 * 这些 id 会写进偏好库，也是设置行的取值判据：读了旧值 / 脏值一律回到默认项。
 * 命名上避开与 hdsMaterial 的 MaterialType / MaterialLevel 同名，故用 Kind / Grade。
 */

/** 主题：跟随系统 / 浅色 / 深色。 */
export enum ThemeMode {
  SYSTEM = 'system',
  LIGHT = 'light',
  DARK = 'dark'
}

/** 语言：跟随系统 / 简体中文 / 英语。 */
export enum AppLanguage {
  SYSTEM = 'system',
  ZH = 'zh',
  EN = 'en'
}

/** 材质类型，映射 hdsMaterial.MaterialType。 */
export enum MaterialKind {
  ADAPTIVE = 'adaptive',
  IMMERSIVE = 'immersive',
  NONE = 'none'
}

/** 沉浸光感材质（四档），映射 hdsMaterial.MaterialLevel。 */
export enum MaterialGrade {
  EXQUISITE = 'exquisite',
  GENTLE = 'gentle',
  SMOOTH = 'smooth',
  ADAPTIVE = 'adaptive'
}

/** 全局背景图：默认图 / 极光 / 暮色 / 自定义（相册图片）/ 关闭（用窗口兜底色）。 */
export enum BackgroundKind {
  DEFAULT = 'default',
  AURORA = 'aurora',
  SUNSET = 'sunset',
  CUSTOM = 'custom',
  NONE = 'none'
}

/** 自动刷新间隔：回到前台时若超过该间隔则自动抓取。 */
export enum AutoRefreshInterval {
  OFF = 'off',
  MIN_15 = '15',
  MIN_30 = '30',
  MIN_60 = '60'
}

/** 列表行样式：纯文字 / 右侧缩略图 / 顶部大图卡片。 */
export enum ListRowLayout {
  TEXT = 'text',
  THUMB = 'thumb',
  CARD = 'card'
}

/** 列表密度：紧凑 / 标准 / 宽松。 */
export enum ListDensity {
  COMPACT = 'compact',
  STANDARD = 'standard',
  RELAXED = 'relaxed'
}

/** 摘要行数：1 / 2 / 3。 */
export enum SummaryLines {
  ONE = '1',
  TWO = '2',
  THREE = '3'
}

/**
 * 密度 → 尺寸资源的映射。
 * 具体数值都落在 float 资源里（紧凑/标准/宽松各一套），这里只做「语义 id → 资源」的翻译，
 * 避免把尺寸散在组件里。
 */
export class ListDensityMetrics {
  /** 行内边距。 */
  static padding(density: string): Resource {
    if (density === ListDensity.COMPACT) {
      return $r('app.float.list_pad_compact');
    }
    if (density === ListDensity.RELAXED) {
      return $r('app.float.list_pad_relaxed');
    }
    return $r('app.float.list_pad_standard');
  }

  /** 行与行的间距。 */
  static gap(density: string): Resource {
    if (density === ListDensity.COMPACT) {
      return $r('app.float.list_gap_compact');
    }
    if (density === ListDensity.RELAXED) {
      return $r('app.float.list_gap_relaxed');
    }
    return $r('app.float.list_gap_standard');
  }

  /** 摘要最多显示几行。 */
  static summaryLines(value: string): number {
    if (value === SummaryLines.ONE) {
      return 1;
    }
    if (value === SummaryLines.THREE) {
      return 3;
    }
    return 2;
  }
}

/** 归档规则：已读且超过阈值的文章不进主列表（OFF 表示不归档）。 */
export enum ArchiveRule {
  OFF = 'off',
  DAYS_7 = '7',
  DAYS_14 = '14',
  DAYS_30 = '30',
  DAYS_90 = '90'
}

/** 归档规则的天数映射（OFF 用 0 表示不归档）。 */
export class ArchiveDays {
  static of(rule: string): number {
    if (rule === ArchiveRule.DAYS_7) {
      return 7;
    }
    if (rule === ArchiveRule.DAYS_14) {
      return 14;
    }
    if (rule === ArchiveRule.DAYS_30) {
      return 30;
    }
    if (rule === ArchiveRule.DAYS_90) {
      return 90;
    }
    return 0;
  }
}

/** 自动刷新间隔的分钟数映射（OFF 用 -1 表示不自动刷新）。 */
export class AutoRefreshMinutes {
  static readonly OFF: number = -1;

  static of(id: string): number {
    if (id === AutoRefreshInterval.MIN_15) {
      return 15;
    }
    if (id === AutoRefreshInterval.MIN_30) {
      return 30;
    }
    if (id === AutoRefreshInterval.MIN_60) {
      return 60;
    }
    return AutoRefreshMinutes.OFF;
  }
}

/** 正文字号档位。 */
export enum ReaderFontSize {
  SMALL = 'small',
  MEDIUM = 'medium',
  LARGE = 'large'
}

/** 正文行距档位。 */
export enum ReaderLineHeight {
  COMPACT = 'compact',
  NORMAL = 'normal',
  LOOSE = 'loose'
}

/** 正文字体族。 */
export enum ReaderFontFamily {
  SYSTEM = 'system',
  SERIF = 'serif',
  SANS = 'sans'
}

/** 阅读栏宽。 */
export enum ReaderWidth {
  NARROW = 'narrow',
  STANDARD = 'standard',
  WIDE = 'wide'
}

/** 正文对齐方式。 */
export enum ReaderAlign {
  LEFT = 'left',
  JUSTIFY = 'justify'
}

/** 阅读主题（Reader 视图专用，独立于应用主题）。 */
export enum ReaderTheme {
  SYSTEM = 'system',
  LIGHT = 'light',
  SEPIA = 'sepia',
  DARK = 'dark'
}

/**
 * 阅读排版：连续档位 → 数值（偏好参数，不是固定视觉尺寸，因此不做成资源）。
 *
 * 字号与行距改成**连续值**（详情页「阅读排版」面板用 Slider 调），
 * 旧的 small/medium/large、compact/normal/loose 只作为快捷预设与老设置的迁移锚点。
 */
export class ReaderTypography {
  /** 字号基准（px）：scale = 1 时正文字号。 */
  static readonly FONT_BASE_PX: number = 17;
  /** 字号连续取值范围。 */
  static readonly FONT_SCALE_MIN: number = 0.8;
  static readonly FONT_SCALE_MAX: number = 1.6;
  /** 行距连续取值范围（行高倍数）。 */
  static readonly LINE_SCALE_MIN: number = 1.2;
  static readonly LINE_SCALE_MAX: number = 2.2;

  /** 字号倍数 → 正文字号（px；Web 注入时按 px 使用）。 */
  static fontSizePx(scale: number): number {
    const clamped: number = Math.min(ReaderTypography.FONT_SCALE_MAX,
      Math.max(ReaderTypography.FONT_SCALE_MIN, scale));
    return Math.round(ReaderTypography.FONT_BASE_PX * clamped * 10) / 10;
  }

  /** 行距倍数（做一次范围收敛，避免脏值把排版撑坏）。 */
  static lineHeightOf(scale: number): number {
    return Math.min(ReaderTypography.LINE_SCALE_MAX, Math.max(ReaderTypography.LINE_SCALE_MIN, scale));
  }

  /** 字号预设 → 倍数（设置页快捷档位 / 老设置迁移）。 */
  static fontScaleOfPreset(id: string): number {
    if (id === ReaderFontSize.SMALL) {
      return 0.9;
    }
    if (id === ReaderFontSize.LARGE) {
      return 1.2;
    }
    return 1.0;
  }

  /** 倍数 → 最接近的字号预设（设置页档位行要显示当前档位）。 */
  static fontPresetOfScale(scale: number): string {
    const presets: string[] = [ReaderFontSize.SMALL, ReaderFontSize.MEDIUM, ReaderFontSize.LARGE];
    let best: string = ReaderFontSize.MEDIUM;
    let bestGap: number = Number.MAX_VALUE;
    for (const id of presets) {
      const gap: number = Math.abs(ReaderTypography.fontScaleOfPreset(id) - scale);
      if (gap < bestGap) {
        bestGap = gap;
        best = id;
      }
    }
    return best;
  }

  /** 行距预设 → 倍数。 */
  static lineScaleOfPreset(id: string): number {
    if (id === ReaderLineHeight.COMPACT) {
      return 1.4;
    }
    if (id === ReaderLineHeight.LOOSE) {
      return 2.0;
    }
    return 1.7;
  }

  /** 倍数 → 最接近的行距预设。 */
  static linePresetOfScale(scale: number): string {
    const presets: string[] = [ReaderLineHeight.COMPACT, ReaderLineHeight.NORMAL, ReaderLineHeight.LOOSE];
    let best: string = ReaderLineHeight.NORMAL;
    let bestGap: number = Number.MAX_VALUE;
    for (const id of presets) {
      const gap: number = Math.abs(ReaderTypography.lineScaleOfPreset(id) - scale);
      if (gap < bestGap) {
        bestGap = gap;
        best = id;
      }
    }
    return best;
  }

  /** 字体族 CSS；system 返回空串（表示不覆盖，跟随系统/站点默认）。 */
  static fontFamilyCss(id: string): string {
    if (id === ReaderFontFamily.SERIF) {
      return 'Georgia, "Times New Roman", "Songti SC", "SimSun", serif';
    }
    if (id === ReaderFontFamily.SANS) {
      return '-apple-system, "HarmonyOS Sans", "PingFang SC", "Microsoft YaHei", sans-serif';
    }
    return '';
  }

  /** 阅读栏宽（px）。 */
  static contentWidthPx(id: string): number {
    if (id === ReaderWidth.NARROW) {
      return 560;
    }
    if (id === ReaderWidth.WIDE) {
      return 900;
    }
    return 720;
  }

  /** 文本对齐 CSS 值。 */
  static textAlignCss(id: string): string {
    return id === ReaderAlign.JUSTIFY ? 'justify' : 'left';
  }
}

/** App logo：经典 / 极光 / 暮色 / 墨黑。 */
export enum LogoKind {
  CLASSIC = 'classic',
  AURORA = 'aurora',
  SUNSET = 'sunset',
  MONO = 'mono'
}

/**
 * 保留策略（是否删除本地文章）：
 * FOREVER 永久保留（默认）；DAYS 按天数清理；UNREAD 仅保留未读与收藏。
 *
 * 注意与「归档规则」（ArchiveRule，只影响列表展示、不删数据）是两套独立机制。
 */
export enum RetentionMode {
  FOREVER = 'forever',
  DAYS = 'days',
  UNREAD = 'unread'
}

/** 保留天数档位（仅在 RetentionMode.DAYS 下生效）。 */
export enum RetentionDays {
  D30 = '30',
  D90 = '90',
  D365 = '365'
}

/**
 * 单源对某个布尔/策略的覆盖：跟随全局 / 强制开 / 强制关。
 * 用于通知（notify）、滚动已读（markReadOnScroll）。
 */
export enum TriState {
  GLOBAL = 'global',
  ON = 'on',
  OFF = 'off'
}

/** 全文策略：跟随全局 / 自动（有 feed 全文就用）/ 总是联网抓原文 / 从不联网。 */
export enum FullTextMode {
  GLOBAL = 'global',
  AUTO = 'auto',
  ALWAYS = 'always',
  NEVER = 'never'
}

/** 保留天数的数值映射（认不出的取值一律当作 90 天）。 */
export class RetentionDaysValue {
  static readonly DEFAULT: number = 90;
  /** 源级「永久保留」哨兵值（与 0 = 跟随全局区分）。 */
  static readonly FOREVER: number = -1;

  static of(id: string): number {
    if (id === RetentionDays.D30) {
      return 30;
    }
    if (id === RetentionDays.D365) {
      return 365;
    }
    if (id === RetentionDays.D90) {
      return 90;
    }
    return RetentionDaysValue.DEFAULT;
  }

  /** 数值 → 最接近的档位 id（设置页展示 / 老数据迁移）。 */
  static idOf(days: number): string {
    if (days === RetentionDaysValue.FOREVER) {
      return 'forever';
    }
    if (days === 30) {
      return RetentionDays.D30;
    }
    if (days === 365) {
      return RetentionDays.D365;
    }
    return RetentionDays.D90;
  }
}

/** 单源抓取间隔档位：'0' = 跟随全局；其余为分钟数。 */
export class FeedIntervalMinutes {
  /** 跟随全局的哨兵值（源级设置里用 0 表示）。 */
  static readonly FOLLOW_GLOBAL: number = 0;

  static of(id: string): number {
    if (id === '15') {
      return 15;
    }
    if (id === '30') {
      return 30;
    }
    if (id === '60') {
      return 60;
    }
    if (id === '180') {
      return 180;
    }
    return FeedIntervalMinutes.FOLLOW_GLOBAL;
  }

  /** 分钟数 → 档位 id（非法 / 负值一律回到「跟随全局」）。 */
  static idOf(minutes: number): string {
    if (minutes === 15) {
      return '15';
    }
    if (minutes === 30) {
      return '30';
    }
    if (minutes === 60) {
      return '60';
    }
    if (minutes === 180) {
      return '180';
    }
    return '0';
  }
}
