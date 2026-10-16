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

/** 阅读排版：档位 → 数值（偏好参数，不是固定视觉尺寸，因此不做成资源）。 */
export class ReaderTypography {
  /** 正文字号（vp；Web 注入时按 px 使用）。 */
  static fontSize(id: string): number {
    if (id === ReaderFontSize.SMALL) {
      return 15;
    }
    if (id === ReaderFontSize.LARGE) {
      return 20;
    }
    return 17;
  }

  /** 行高倍数。 */
  static lineHeight(id: string): number {
    if (id === ReaderLineHeight.COMPACT) {
      return 1.4;
    }
    if (id === ReaderLineHeight.LOOSE) {
      return 2.0;
    }
    return 1.7;
  }
}

/** App logo：经典 / 极光 / 暮色 / 墨黑。 */
export enum LogoKind {
  CLASSIC = 'classic',
  AURORA = 'aurora',
  SUNSET = 'sunset',
  MONO = 'mono'
}
