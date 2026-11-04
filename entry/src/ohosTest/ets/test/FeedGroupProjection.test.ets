import { describe, it, expect } from '@ohos/hypium';
import { Article } from '../../../main/ets/model/Feed';
import { GroupMode } from '../../../main/ets/common/constants/RssConstants';
import { ArticleGroup } from '../../../main/ets/viewmodel/ArticleDataSource';
import { buildArticleGroups } from '../../../main/ets/viewmodel/FeedGroupProjection';

export default function feedGroupProjectionTest(): void {
  describe('FeedGroupProjection', () => {
    it('keeps_first_seen_feed_order_and_counts_unread_items', 0, () => {
      const first: Article = new Article('a', 'feed-a', 'A', 'First', '', '', '', 30);
      const second: Article = new Article('b', 'feed-b', 'B', 'Second', '', '', '', 20);
      const third: Article = new Article('c', 'feed-a', 'A', 'Third', '', '', '', 10);
      second.read = true;

      const groups: ArticleGroup[] = buildArticleGroups([first, second, third], GroupMode.FEED);
      expect(groups.length).assertEqual(2);
      expect(groups[0].key).assertEqual('feed-a');
      expect(groups[0].total).assertEqual(2);
      expect(groups[0].unread).assertEqual(2);
      expect(groups[0].source.getData(0)).assertEqual(first);
      expect(groups[0].source.getData(1)).assertEqual(third);
      expect(groups[1].key).assertEqual('feed-b');
      expect(groups[1].unread).assertEqual(0);
    });
  });
}
