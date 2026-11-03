/* Domain instances share one RDB connection; callers import only the capability they use. */
import { ArticleDatabase } from './ArticleDatabase';
import { ArticleSearchStore } from './ArticleSearchStore';
import { ArticleRepository } from './ArticleRepository';
import { HighlightStore } from './HighlightStore';

export { ArticleBody, CacheStats, WidgetSnapshot, SavedWebPageResult, BackupMergeCount } from './ArticleSchema';

export const articleRepository: ArticleRepository = new ArticleRepository();
export const articleDatabase: ArticleDatabase = articleRepository;
export const articleSearchStore: ArticleSearchStore = articleRepository;
export const highlightStore: HighlightStore = new HighlightStore(articleDatabase);
