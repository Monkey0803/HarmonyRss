/*
 * PreferencesConstants.ets — 偏好库（@ohos.data.preferences）的库名与 key。
 *
 * key 是纯逻辑字符串，集中在这里，避免在读写两端各写一遍。
 */
export class PreferencesConstants {
  static readonly STORE_NAME: string = 'hds_app_settings_v1';
  static readonly KEY_THEME_MODE: string = 'themeMode';
  static readonly KEY_LANGUAGE_MODE: string = 'languageMode';
  static readonly KEY_MATERIAL_TYPE: string = 'materialType';
  static readonly KEY_MATERIAL_LEVEL: string = 'materialLevel';
  /** 全局背景图（语义 id）。 */
  static readonly KEY_BACKGROUND_KIND: string = 'backgroundKind';
  /** 自定义全局背景图的沙箱路径。 */
  static readonly KEY_BACKGROUND_IMAGE_PATH: string = 'backgroundImagePath';
  /** 标题栏是否随内容滚动（动态隐藏标题栏）。 */
  static readonly KEY_TITLE_BAR_SCROLL: string = 'titleBarScrollsWithContent';
  static readonly KEY_STATUS_BAR_SCROLL: string = 'statusBarScrollsWithContent';
  /** 自动刷新间隔（'off' | '15' | '30' | '60'）。 */
  static readonly KEY_AUTO_REFRESH: string = 'autoRefresh';
  /** 阅读排版：正文字号档位。 */
  static readonly KEY_READER_FONT: string = 'readerFont';
  /** 正文字号倍数（连续值）。 */
  static readonly KEY_READER_FONT_SCALE: string = 'readerFontScale';
  /** 正文行距倍数（连续值）。 */
  static readonly KEY_READER_LINE_SCALE: string = 'readerLineScale';
  /** 阅读排版：正文行距档位。 */
  static readonly KEY_READER_LINE: string = 'readerLine';
  /** 阅读排版：字体族。 */
  static readonly KEY_READER_FAMILY: string = 'readerFontFamily';
  /** 阅读排版：栏宽。 */
  static readonly KEY_READER_WIDTH: string = 'readerWidth';
  /** 阅读排版：对齐。 */
  static readonly KEY_READER_ALIGN: string = 'readerAlign';
  /** 阅读主题。 */
  static readonly KEY_READER_THEME: string = 'readerTheme';
  /** 新文章通知开关。 */
  static readonly KEY_NOTIFY_NEW: string = 'notifyNewArticles';
  static readonly KEY_IMMERSIVE_ON: string = 'immersiveOn';
  static readonly KEY_POINT_LIGHT: string = 'pointLightEnabled';
  static readonly KEY_GRIP_ENABLED: string = 'gripEnabled';
  static readonly KEY_ANTI_PEEP_ENABLED: string = 'antiPeepEnabled';
  /** App logo 变体（语义 id）。 */
  static readonly KEY_LOGO_KIND: string = 'logoKind';
  /** RSS 订阅源列表（JSON 数组字符串）。 */
  static readonly KEY_RSS_FEEDS: string = 'rssFeeds';
}
