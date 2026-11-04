/* Shared visibility and archive policy for list and navigation projections. */
import { Article } from '../model/Feed';
import { ArticleFilter } from '../common/constants/RssConstants';
import { appSettings } from '../model/AppSettings';
import { ArchiveDays } from '../common/constants/SettingsConstants';

const DAY_MS: number = 24 * 60 * 60 * 1000;

export function passesArticleFilter(item: Article, filter: string, scopeFeedId: string): boolean {
  if (scopeFeedId.length > 0 && item.feedId !== scopeFeedId) {
    return false;
  }
  // 隐藏口径优先：HIDDEN 筛选只保留被规则隐藏的文章；其余筛选一律排除隐藏文章。
  if (filter === ArticleFilter.HIDDEN) {
    return item.hidden;
  }
  if (item.hidden) {
    return false;
  }
  if (filter === ArticleFilter.ARCHIVED) {
    return isArchivedArticle(item);
  }
  // 归档的文章只在「归档」里出现；其余视图一律排除（否则规则形同虚设）。
  if (isArchivedArticle(item)) {
    return false;
  }
  if (filter === ArticleFilter.UNREAD && item.read) {
    return false;
  }
  if (filter === ArticleFilter.STARRED && !item.starred) {
    return false;
  }
  if (filter === ArticleFilter.SAVED && !item.saved) {
    return false;
  }
  return true;
}

export function isArchivedArticle(item: Article): boolean {
  const days: number = ArchiveDays.of(appSettings.archiveRule);
  if (days <= 0 || item.saved || !item.read || item.publishedAt <= 0) {
    return false;
  }
  return Date.now() - item.publishedAt > days * DAY_MS;
}
