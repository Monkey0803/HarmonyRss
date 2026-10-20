/*
 * AppSettings.ets — 应用设置状态（ArkTS 状态管理 V2）。
 *
 * 用 @ObservedV2 + @Trace：状态被任何持有者读取都会建立观察关系，所以这里做成模块级
 * 单例（appSettings），界面直接 import 读写即可，不需要在组件间层层传参。
 */

import { ArticleFilter, GroupMode, ReaderViewMode } from '../common/constants/RssConstants';
import { ArchiveRule } from '../common/constants/SettingsConstants';
import { THEME_OPTIONS, LANGUAGE_OPTIONS, MATERIAL_TYPE_OPTIONS, MATERIAL_LEVEL_OPTIONS, BACKGROUND_OPTIONS, LOGO_OPTIONS, AUTO_REFRESH_OPTIONS, READER_FONT_OPTIONS, READER_LINE_OPTIONS, READER_FAMILY_OPTIONS, READER_WIDTH_OPTIONS, READER_ALIGN_OPTIONS, READER_THEME_OPTIONS } from './SettingsOptions';

@ObservedV2
export class AppSettings {
  /** 主题：'system' | 'light' | 'dark'。 */
  @Trace themeMode: string = THEME_OPTIONS.defaultValue;
  /** 语言：'system' | 'zh' | 'en'。 */
  @Trace languageMode: string = LANGUAGE_OPTIONS.defaultValue;
  /** 沉浸光感总开关。 */
  @Trace immersiveOn: boolean = true;
  /** 点光源效果开关（hdsEffect pointLight）。 */
  @Trace pointLightEnabled: boolean = true;
  /** 材质类型：'adaptive' | 'immersive' | 'none'。 */
  @Trace materialType: string = MATERIAL_TYPE_OPTIONS.defaultValue;
  /** 沉浸光感材质四档：'exquisite' | 'gentle' | 'smooth' | 'adaptive'。 */
  @Trace materialLevel: string = MATERIAL_LEVEL_OPTIONS.defaultValue;
  /** 全局背景图：'default' | 'aurora' | 'sunset' | 'custom' | 'none'。 */
  @Trace backgroundKind: string = BACKGROUND_OPTIONS.defaultValue;
  /** 自定义背景图的沙箱路径（backgroundKind 为 'custom' 时使用）。 */
  @Trace backgroundImagePath: string = '';
  /** 标题栏是否随内容滚动：false 时标题栏固定、内容从标题栏下滚过；true 时滚动会收起标题栏。 */
  @Trace titleBarScrollsWithContent: boolean = false;
  /** 状态栏是否随内容滚动：true 时滚动内容会一并收起状态栏（沉浸光感建议开启，交给用户决定）。 */
  @Trace statusBarScrollsWithContent: boolean = false;
  /** 智感握姿：悬浮页签是否跟随握持手。 */
  @Trace gripEnabled: boolean = true;
  /** 防窥保护总开关。 */
  @Trace antiPeepEnabled: boolean = false;
  /** App logo 变体：'classic' | 'aurora' | 'sunset' | 'mono'。 */
  @Trace logoKind: string = LOGO_OPTIONS.defaultValue;
  /** 自动刷新间隔：'off' | '15' | '30' | '60'（分钟，回到前台时判断是否过期）。 */
  @Trace autoRefresh: string = AUTO_REFRESH_OPTIONS.defaultValue;
  /** 正文字号倍数（0.8–1.6，连续值；详情页「阅读排版」面板用 Slider 调）。 */
  @Trace readerFontScale: number = 1.0;
  /** 正文字号档位（'small' | 'medium' | 'large'）：由倍数推出的最接近预设，设置页档位行显示用。 */
  @Trace readerFont: string = READER_FONT_OPTIONS.defaultValue;
  /** 阅读时常亮屏幕（进入详情页开启、离开恢复）。 */
  @Trace readerKeepScreenOn: boolean = true;
  /** 正文行距倍数（1.2–2.2，连续值）。 */
  @Trace readerLineScale: number = 1.7;
  /** 正文行距档位（'compact' | 'normal' | 'loose'）：由倍数推出的最接近预设。 */
  @Trace readerLine: string = READER_LINE_OPTIONS.defaultValue;
  /** 正文字体：'system' | 'serif' | 'sans'。 */
  @Trace readerFontFamily: string = READER_FAMILY_OPTIONS.defaultValue;
  /** 阅读栏宽：'narrow' | 'standard' | 'wide'。 */
  @Trace readerWidth: string = READER_WIDTH_OPTIONS.defaultValue;
  /** 正文对齐：'left' | 'justify'。 */
  @Trace readerAlign: string = READER_ALIGN_OPTIONS.defaultValue;
  /** 阅读主题：'system' | 'light' | 'sepia' | 'dark'。 */
  @Trace readerTheme: string = READER_THEME_OPTIONS.defaultValue;
  /** 后台抓取到新文章时是否发系统通知。 */
  @Trace notifyNewArticles: boolean = false;
  /** 首页列表排序：true = 最新在前（默认），false = 最旧在前。 */
  @Trace listNewestFirst: boolean = true;
  /** 首页列表分组方式：'none' = 平铺，'feed' = 按订阅源，'date' = 按日期。 */
  @Trace listGroupMode: string = GroupMode.NONE;
  /** 首页筛选：'all' = 全部，'unread' = 未读，'starred' = 收藏。 */
  @Trace homeFilter: string = ArticleFilter.ALL;
  /** 上次停留的页签下标。 */
  @Trace lastTabIndex: number = 0;
  /** 详情页阅读模式：ReaderViewMode.READER | ReaderViewMode.WEB。 */
  @Trace readerViewMode: string = ReaderViewMode.READER;
  /** 归档规则：ArchiveRule（已读且超过该天数的文章不进主列表，进「归档」）。 */
  @Trace archiveRule: string = ArchiveRule.DAYS_30;
}

/** 全局唯一设置实例。 */
export const appSettings: AppSettings = new AppSettings();
