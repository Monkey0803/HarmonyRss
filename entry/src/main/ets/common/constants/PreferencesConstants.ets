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
  static readonly KEY_READER_KEEP_SCREEN_ON: string = 'readerKeepScreenOn';
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
  /** 首页列表排序：true = 最新在前。 */
  static readonly KEY_LIST_NEWEST_FIRST: string = 'listNewestFirst';
  /** 首页列表分组方式：'none' | 'feed' | 'date'。 */
  static readonly KEY_LIST_GROUP_MODE: string = 'listGroupMode';
  /** 首页筛选：'all' | 'unread' | 'starred'。 */
  static readonly KEY_HOME_FILTER: string = 'homeFilter';
  /** 上次停留的页签下标（阅读 / 订阅源 / 设置 …）。 */
  static readonly KEY_LAST_TAB: string = 'lastTabIndex';
  /** 列表行样式：'text' | 'thumb' | 'card'。 */
  static readonly KEY_ROW_LAYOUT: string = 'listRowLayout';
  /** 摘要行数：'1' | '2' | '3'。 */
  static readonly KEY_SUMMARY_LINES: string = 'listSummaryLines';
  /** 列表密度：'compact' | 'standard' | 'relaxed'。 */
  static readonly KEY_LIST_DENSITY: string = 'listDensity';
  /** 归档规则：'off' | '7' | '14' | '30' | '90'（已读且超过该天数的文章不进主列表）。 */
  static readonly KEY_ARCHIVE_RULE: string = 'archiveRule';
  /** 详情页阅读模式：'reader' = 阅读器，其它 = 原文。 */
  static readonly KEY_READER_VIEW_MODE: string = 'readerViewMode';
  static readonly KEY_POINT_LIGHT: string = 'pointLightEnabled';
  static readonly KEY_GRIP_ENABLED: string = 'gripEnabled';
  static readonly KEY_ANTI_PEEP_ENABLED: string = 'antiPeepEnabled';
  /** App logo 变体（语义 id）。 */
  static readonly KEY_LOGO_KIND: string = 'logoKind';
  /** RSS 订阅源列表（JSON 数组字符串）。 */
  static readonly KEY_RSS_FEEDS: string = 'rssFeeds';
  /** 保留策略：'forever' | 'days' | 'unread'（是否删除本地文章）。 */
  static readonly KEY_RETENTION_MODE: string = 'retentionMode';
  /** 保留天数档位：'30' | '90' | '365'（仅 days 模式生效）。 */
  static readonly KEY_RETENTION_DAYS: string = 'retentionDays';
  /** 最近一次自动保留清理的时间戳（6 小时节流用）。 */
  static readonly KEY_LAST_RETENTION_RUN: string = 'lastRetentionRun';
  /** 搜索历史（JSON 字符串数组，最多 20 条，最新在前）。 */
  static readonly KEY_SEARCH_HISTORY: string = 'searchHistory';
  /** 远端服务自动同步间隔（'off' | '15' | '30' | '60'；默认关）。 */
  static readonly KEY_REMOTE_AUTO_SYNC: string = 'remoteAutoSync';
  /** 跨源去重总开关（默认开；关闭后只影响新入库文章，已有合并组保持现状）。 */
  static readonly KEY_DEDUPE_ENABLED: string = 'dedupeEnabled';
  /** 自定义分享模板（JSON 数组：id / name / content / sort）。 */
  static readonly KEY_SHARE_TEMPLATES: string = 'shareTemplates';
  /** 最近一次自动快照的日期（yyyyMMdd），避免同一天重复生成。 */
  static readonly KEY_LAST_SNAPSHOT_AT: string = 'lastSnapshotAt';
  // ---- 通知策略（免打扰 / 摘要 / 关键词） ----
  /** 免打扰开关（默认开）。 */
  static readonly KEY_NOTIFY_DND_ENABLED: string = 'notifyDndEnabled';
  /** 免打扰开始时间（当天第几分钟，0–1439；默认 1380 = 23:00）。 */
  static readonly KEY_NOTIFY_DND_START: string = 'notifyDndStart';
  /** 免打扰结束时间（当天第几分钟，0–1439；默认 480 = 08:00）。 */
  static readonly KEY_NOTIFY_DND_END: string = 'notifyDndEnd';
  /** 每日摘要开关（默认关）。 */
  static readonly KEY_NOTIFY_DIGEST_ENABLED: string = 'notifyDigestEnabled';
  /** 每日摘要触发小时（0–23；默认 20）。 */
  static readonly KEY_NOTIFY_DIGEST_HOUR: string = 'notifyDigestHour';
  /** 全局通知关键词（JSON 字符串数组，最多 20 条）。 */
  static readonly KEY_NOTIFY_KEYWORDS: string = 'notifyKeywords';
  /** 免打扰期间待通知队列（JSON：`[{articleId, feedId, at}]`，最多 50 条）。 */
  static readonly KEY_NOTIFY_QUEUE: string = 'notifyQueue';
  /** 最近一次发送每日摘要的本地日期（YYYY-MM-DD）。 */
  static readonly KEY_NOTIFY_LAST_DIGEST: string = 'notifyLastDigest';
  // ---- 正文翻译（服务端点与开关；API Key 在 Asset Store） ----
  /** 联网翻译开关（默认关）。 */
  static readonly KEY_TRANSLATE_ENABLED: string = 'translateEnabled';
  /** 翻译服务：'deepl' | 'libre'。 */
  static readonly KEY_TRANSLATE_PROVIDER: string = 'translateProvider';
  /** 自定义服务端点（空串 = 服务默认端点）。 */
  static readonly KEY_TRANSLATE_ENDPOINT: string = 'translateEndpoint';
}
