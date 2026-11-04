/* Whitelisted backup fields, export sanitization and import merge policy. */
import { ArticleStatePatch, BackupArticle, BackupFeed } from '../model/Backup';
import { Article, FeedSource } from '../model/Feed';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';

/** 设置段白名单：只备份跨设备仍有意义、且不包含路径 / 凭据的偏好。 */
const SETTINGS_WHITELIST: string[] = [
  PreferencesConstants.KEY_THEME_MODE,
  PreferencesConstants.KEY_THEME_COLOR,
  PreferencesConstants.KEY_LANGUAGE_MODE,
  PreferencesConstants.KEY_MATERIAL_TYPE,
  PreferencesConstants.KEY_MATERIAL_LEVEL,
  PreferencesConstants.KEY_BACKGROUND_KIND,
  PreferencesConstants.KEY_IMMERSIVE_ON,
  PreferencesConstants.KEY_POINT_LIGHT,
  PreferencesConstants.KEY_TITLE_BAR_SCROLL,
  PreferencesConstants.KEY_STATUS_BAR_SCROLL,
  PreferencesConstants.KEY_LOGO_KIND,
  PreferencesConstants.KEY_AUTO_REFRESH,
  PreferencesConstants.KEY_READER_KEEP_SCREEN_ON,
  PreferencesConstants.KEY_READER_FONT,
  PreferencesConstants.KEY_READER_FONT_SCALE,
  PreferencesConstants.KEY_READER_LINE_SCALE,
  PreferencesConstants.KEY_READER_LINE,
  PreferencesConstants.KEY_READER_FAMILY,
  PreferencesConstants.KEY_READER_WIDTH,
  PreferencesConstants.KEY_READER_ALIGN,
  PreferencesConstants.KEY_READER_THEME,
  PreferencesConstants.KEY_READER_INDENT,
  PreferencesConstants.KEY_PREFETCH_READER,
  PreferencesConstants.KEY_NOTIFY_NEW,
  PreferencesConstants.KEY_LIST_NEWEST_FIRST,
  PreferencesConstants.KEY_LIST_GROUP_MODE,
  PreferencesConstants.KEY_HOME_FILTER,
  PreferencesConstants.KEY_READER_VIEW_MODE,
  PreferencesConstants.KEY_ROW_LAYOUT,
  PreferencesConstants.KEY_SUMMARY_LINES,
  PreferencesConstants.KEY_LIST_DENSITY,
  PreferencesConstants.KEY_ARCHIVE_RULE,
  PreferencesConstants.KEY_DEDUPE_ENABLED,
  PreferencesConstants.KEY_REMOTE_AUTO_SYNC
];
const SETTINGS_WHITELIST_SET: Set<string> = new Set<string>(SETTINGS_WHITELIST);

export function isPresent(value: string): boolean {
  return value.length > 0;
}

// ---- 各段解析（缺字段给默认值；没有主键的脏行跳过） ----

/**
 * 合并同一篇文章的阅读状态（导入幂等核心）。
 * read / starred / saved / hidden 取 OR；progress / progressRatio 取 max；
 * canonicalId 保留 existing 的非空值（旧库已有主条关系时不被打断）。
 */
export function mergeArticleState(existing: ArticleStatePatch,
  incoming: ArticleStatePatch): ArticleStatePatch {
  return new ArticleStatePatch(
    existing.read || incoming.read,
    existing.starred || incoming.starred,
    existing.saved || incoming.saved,
    existing.hidden || incoming.hidden,
    Math.max(existing.progress, incoming.progress),
    Math.max(existing.progressRatio, incoming.progressRatio),
    isPresent(existing.canonicalId) ? existing.canonicalId : incoming.canonicalId
  );
}

/** 设置段白名单（返回副本，调用方修改不会污染全局常量）。 */
export function settingsWhitelist(): string[] {
  return SETTINGS_WHITELIST.slice();
}

/** 某个偏好 key 是否允许写入备份 / 从备份恢复。 */
export function isSettingsKeyAllowed(key: string): boolean {
  return SETTINGS_WHITELIST_SET.has(key);
}

/**
 * 导出订阅：只保留恢复所需字段。
 * 丢弃 etag / lastModified / 抓取失败次数 / 统计等设备相关或派生字段。
 */
export function sanitizeFeed(feed: FeedSource): BackupFeed {
  const url: string = isPresent(feed.url) ? feed.url : feed.id;
  return new BackupFeed(url, feed.title, feed.siteUrl, feed.group, feed.enabled,
    feed.fetchIntervalMinutes, feed.fullTextMode, feed.retentionDays, feed.notify,
    feed.markReadOnScroll);
}

/**
 * 导出文章：只保留元数据 + 阅读状态。
 * 丢弃 content / contentHtml / readerHtml / plainText / pageEtag / duplicateCount 等
 * 正文缓存与派生字段（体积可控，且不泄露抓取凭据）。
 */
export function sanitizeArticle(article: Article): BackupArticle {
  return new BackupArticle(article.id, article.feedId, article.feedTitle, article.title,
    article.link, article.summary, article.author, article.publishedAt, article.imageUrl,
    article.read, article.starred, article.saved, article.hidden, article.progress,
    article.progressRatio, article.canonicalId, article.linkKey, article.titleKey);
}
