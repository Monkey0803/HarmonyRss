/*
 * RemoteSyncPlan.test.ets — 同步纯逻辑：订阅合并 / 冲突决策 / edit-tag 分批。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  buildEditTagBatches,
  decideState,
  FeedMergeResult,
  localOnlyFeeds,
  mergeFeeds
} from '../../../main/ets/service/remote/RemoteSyncPlan';
import { ArticleState, EditTagOp, GReaderTags, OutboxItem, RemoteFeed, StateDecision } from '../../../main/ets/model/Remote';
import { FeedSource } from '../../../main/ets/model/Feed';

function feed(url: string, title: string, group: string = ''): FeedSource {
  return new FeedSource(url, title, url, '', group);
}

function outbox(articleId: string, read: boolean | undefined, starred: boolean | undefined): OutboxItem {
  const item: OutboxItem = new OutboxItem(articleId);
  if (read !== undefined) {
    item.setRead = true;
    item.readValue = read;
  }
  if (starred !== undefined) {
    item.setStarred = true;
    item.starredValue = starred;
  }
  return item;
}

export default function remoteSyncPlanTest() {
  describe('RemoteSyncPlan', () => {
    it('merge_keeps_local_and_adds_remote', 0, () => {
      const local: FeedSource[] = [feed('https://local.com/rss', 'Local')];
      const remote: RemoteFeed[] = [
        new RemoteFeed('feed/https://remote.com/rss', 'https://remote.com/rss', 'Remote', 'News')
      ];
      const result: FeedMergeResult = mergeFeeds(local, remote);
      expect(result.feeds.length).assertEqual(2);
      expect(result.added).assertEqual(1);
      expect(result.changed).assertTrue();
      expect(result.feeds[0].title).assertEqual('Local');
      expect(result.feeds[1].url).assertEqual('https://remote.com/rss');
      expect(result.feeds[1].group).assertEqual('News');
    });

    it('merge_matches_by_normalized_url', 0, () => {
      const local: FeedSource[] = [feed('https://a.com/rss/', '自定义标题')];
      const remote: RemoteFeed[] = [
        new RemoteFeed('feed/https://a.com/rss', 'https://a.com/rss', 'A', 'Tech')
      ];
      const result: FeedMergeResult = mergeFeeds(local, remote);
      expect(result.feeds.length).assertEqual(1);
      expect(result.added).assertEqual(0);
      // 用户自定义标题不被覆盖。
      expect(result.feeds[0].title).assertEqual('自定义标题');
      // 分组为空时补上远端分组。
      expect(result.feeds[0].group).assertEqual('Tech');
      expect(result.changed).assertTrue();
    });

    it('merge_dedupes_remote_urls', 0, () => {
      const remote: RemoteFeed[] = [
        new RemoteFeed('feed/https://a.com/rss', 'https://a.com/rss', 'A'),
        new RemoteFeed('feed/https://a.com/rss/', 'https://a.com/rss/', 'A2')
      ];
      const result: FeedMergeResult = mergeFeeds([], remote);
      expect(result.feeds.length).assertEqual(1);
      expect(result.added).assertEqual(1);
    });

    it('decide_state_push_first', 0, () => {
      const local: ArticleState = new ArticleState('a', true, false);
      const inOutbox: StateDecision = decideState(local.read, local.starred, false, true, true);
      expect(inOutbox.read).assertTrue();
      expect(inOutbox.starred).assertFalse();
      const clean: StateDecision = decideState(local.read, local.starred, false, true, false);
      expect(clean.read).assertFalse();
      expect(clean.starred).assertTrue();
    });


    it('local_only_feeds_normalized', 0, () => {
      const local: FeedSource[] = [
        feed('https://a.com/rss/', 'A'),
        feed('https://b.com/rss', 'B'),
        feed('https://c.com/rss', 'C')
      ];
      const remote: RemoteFeed[] = [
        new RemoteFeed('feed/https://a.com/rss', 'https://a.com/rss', 'A'),
        new RemoteFeed('feed/https://c.com/rss', 'https://c.com/rss', 'C')
      ];
      const only: FeedSource[] = localOnlyFeeds(local, remote);
      expect(only.length).assertEqual(1);
      expect(only[0].url).assertEqual('https://b.com/rss');
      expect(localOnlyFeeds(local, []).length).assertEqual(3);
    });

    it('edit_tag_batches_split_and_tags', 0, () => {
      const items: OutboxItem[] = [
        outbox('a1', true, undefined),
        outbox('a2', undefined, true),
        outbox('a3', false, false)
      ];
      const remoteIds: Map<string, string> = new Map<string, string>();
      remoteIds.set('a1', 'r1');
      remoteIds.set('a2', 'r2');
      remoteIds.set('a3', 'r3');
      remoteIds.set('a4', 'r4');
      const batches: EditTagOp[][] = buildEditTagBatches(items, remoteIds, 2);
      expect(batches.length).assertEqual(2);
      expect(batches[0].length).assertEqual(2);
      expect(batches[1].length).assertEqual(1);
      expect(batches[0][0].remoteId).assertEqual('r1');
      expect(batches[0][0].addTags[0]).assertEqual(GReaderTags.READ);
      expect(batches[0][0].removeTags.length).assertEqual(0);
      expect(batches[0][1].addTags[0]).assertEqual(GReaderTags.STARRED);
      // 取消已读 / 收藏 → remove 标签。
      expect(batches[1][0].removeTags.length).assertEqual(2);
    });

    it('edit_tag_skips_unmapped_and_noop', 0, () => {
      const items: OutboxItem[] = [outbox('a1', true, undefined), outbox('a2', true, undefined)];
      const remoteIds: Map<string, string> = new Map<string, string>();
      remoteIds.set('a1', 'r1');
      const batches: EditTagOp[][] = buildEditTagBatches(items, remoteIds, 10);
      expect(batches.length).assertEqual(1);
      expect(batches[0].length).assertEqual(1);
      expect(buildEditTagBatches(items, new Map<string, string>(), 10).length).assertEqual(0);
    });
  });
}
