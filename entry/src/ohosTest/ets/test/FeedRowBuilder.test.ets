/*
 * FeedRowBuilder.test.ets — 订阅管理列表的行展开与分组聚合纯函数单测。
 */

import { describe, it, expect } from '@ohos/hypium';
import { FeedGroup, FeedListItem, FeedSource } from '../../../main/ets/model/Feed';
import {
  buildFeedRows,
  groupCount,
  groupUnread,
  isLastFeedInGroup
} from '../../../main/ets/viewmodel/FeedRowBuilder';

function makeFeed(id: string, group: string, unread: number): FeedSource {
  const feed: FeedSource = new FeedSource(id, id, id, '', group);
  feed.unreadCount = unread;
  return feed;
}

export default function feedRowBuilderTest() {
  describe('FeedRowBuilder', () => {
    const a: FeedSource = makeFeed('a', 'Tech', 2);
    const b: FeedSource = makeFeed('b', 'Tech', 3);
    const c: FeedSource = makeFeed('c', '', 1);
    const groups: FeedGroup[] = [new FeedGroup('Tech', [a, b]), new FeedGroup('', [c])];

    it('expands_groups_in_order', 0, () => {
      const rows: FeedListItem[] = buildFeedRows(groups, []);
      expect(rows.length).assertEqual(5);
      expect(rows[0].isGroup).assertTrue();
      expect(rows[0].groupName).assertEqual('Tech');
      expect(rows[1].isGroup).assertFalse();
      expect(rows[1].feed.id).assertEqual('a');
      expect(rows[2].feed.id).assertEqual('b');
      expect(rows[3].isGroup).assertTrue();
      expect(rows[3].groupName).assertEqual('');
      expect(rows[4].feed.id).assertEqual('c');
    });

    it('collapses_group_to_header_only', 0, () => {
      const rows: FeedListItem[] = buildFeedRows(groups, ['Tech']);
      expect(rows.length).assertEqual(3);
      expect(rows[0].isGroup).assertTrue();
      expect(rows[1].isGroup).assertTrue();
      expect(rows[2].feed.id).assertEqual('c');
    });

    it('can_collapse_ungrouped_bucket', 0, () => {
      const rows: FeedListItem[] = buildFeedRows(groups, ['']);
      expect(rows.length).assertEqual(4);
      expect(rows[0].isGroup).assertTrue();
      expect(rows[3].isGroup).assertTrue();
      expect(rows[3].groupName).assertEqual('');
    });

    it('counts_group_and_unread', 0, () => {
      const feeds: FeedSource[] = [a, b, c];
      expect(groupCount(feeds, 'Tech')).assertEqual(2);
      expect(groupCount(feeds, '')).assertEqual(1);
      expect(groupUnread(feeds, 'Tech')).assertEqual(5);
      expect(groupUnread(feeds, '')).assertEqual(1);
    });

    it('detects_last_feed_in_group', 0, () => {
      const feeds: FeedSource[] = [a, b, c];
      expect(isLastFeedInGroup(feeds, 'a')).assertFalse();
      expect(isLastFeedInGroup(feeds, 'b')).assertTrue();
      expect(isLastFeedInGroup(feeds, 'c')).assertTrue();
      expect(isLastFeedInGroup(feeds, 'missing')).assertFalse();
    });
  });
}
