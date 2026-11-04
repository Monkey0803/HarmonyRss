import { describe, it, expect } from '@ohos/hypium';
import { Article } from '../../../main/ets/model/Feed';
import { ArticleFilter } from '../../../main/ets/common/constants/RssConstants';
import { passesArticleFilter } from '../../../main/ets/viewmodel/FeedArticleFilter';

export default function feedArticleFilterTest(): void {
  describe('FeedArticleFilter', () => {
    it('keeps_hidden_and_scope_rules_consistent_across_filters', 0, () => {
      const article: Article = new Article('a', 'feed-a', 'A', 'Title', '', '', '', Date.now());
      expect(passesArticleFilter(article, ArticleFilter.ALL, 'feed-a')).assertTrue();
      expect(passesArticleFilter(article, ArticleFilter.ALL, 'feed-b')).assertFalse();
      article.hidden = true;
      expect(passesArticleFilter(article, ArticleFilter.ALL, 'feed-a')).assertFalse();
      expect(passesArticleFilter(article, ArticleFilter.HIDDEN, 'feed-a')).assertTrue();
      article.hidden = false;
      article.read = true;
      expect(passesArticleFilter(article, ArticleFilter.UNREAD, 'feed-a')).assertFalse();
    });
  });
}
