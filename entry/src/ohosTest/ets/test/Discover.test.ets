/*
 * Discover.test.ets — 发现页纯逻辑单测。
 *
 * 覆盖：精选目录完整性、分类 / 热门 / 关键词筛选、已订阅归一化判定、
 * 本地相似源推荐（排除已订阅 / 受 limit 约束），以及 RSSHub 路由推导与实例归一化。
 */

import { describe, it, expect } from '@ohos/hypium';
import { DiscoverCatalog, DiscoverCategory } from '../../../main/ets/model/Discover';
import { DiscoverService, normalizeFeedKey } from '../../../main/ets/service/DiscoverService';
import {
  DEFAULT_RSSHUB_BASE,
  normalizeRssHubBase,
  RssHubKind,
  RssHubRoutes,
  RssHubSuggestion
} from '../../../main/ets/service/RssHubRoutes';
import { FeedSource } from '../../../main/ets/model/Feed';

function routeList(input: string): RssHubSuggestion[] {
  return RssHubRoutes.suggest(input, DEFAULT_RSSHUB_BASE);
}

function kinds(list: RssHubSuggestion[]): string[] {
  const result: string[] = [];
  for (let i = 0; i < list.length; i += 1) {
    result.push(list[i].kind);
  }
  return result;
}

function routes(list: RssHubSuggestion[]): string[] {
  const result: string[] = [];
  for (let i = 0; i < list.length; i += 1) {
    result.push(list[i].route);
  }
  return result;
}

export default function discoverTest() {
  describe('Discover', () => {
    it('catalog_is_valid', 0, () => {
      expect(DiscoverCatalog.FEEDS.length >= 20).assertTrue();
      const seen: Set<string> = new Set();
      for (let i = 0; i < DiscoverCatalog.FEEDS.length; i += 1) {
        const feed = DiscoverCatalog.FEEDS[i];
        expect(feed.title.length > 0).assertTrue();
        expect(feed.feedUrl.startsWith('https://')).assertTrue();
        expect(feed.category.length > 0).assertTrue();
        expect(feed.tags.length > 0).assertTrue();
        expect(feed.popularity >= 0 && feed.popularity <= 100).assertTrue();
        const key: string = normalizeFeedKey(feed.feedUrl);
        expect(seen.has(key)).assertFalse();
        seen.add(key);
      }
    });

    it('filter_by_category_and_keyword', 0, () => {
      const all = DiscoverService.filter(DiscoverCategory.ALL, '');
      expect(all.length).assertEqual(DiscoverCatalog.FEEDS.length);

      const tech = DiscoverService.filter(DiscoverCategory.TECH, '');
      expect(tech.length > 0).assertTrue();
      for (let i = 0; i < tech.length; i += 1) {
        const feed = tech[i];
        expect(feed.category === DiscoverCategory.TECH
          || feed.tags.indexOf(DiscoverCategory.TECH) >= 0).assertTrue();
      }

      const vercel = DiscoverService.filter(DiscoverCategory.ALL, 'the verge');
      expect(vercel.length).assertEqual(1);
      expect(vercel[0].feedUrl).assertEqual('https://www.theverge.com/rss/index.xml');

      const none = DiscoverService.filter(DiscoverCategory.ALL, 'not-a-real-feed-keyword');
      expect(none.length).assertEqual(0);
    });

    it('hot_is_sorted_by_popularity', 0, () => {
      const hot = DiscoverService.filter(DiscoverCategory.HOT, '');
      expect(hot.length).assertEqual(DiscoverCatalog.FEEDS.length);
      for (let i = 1; i < hot.length; i += 1) {
        expect(hot[i - 1].popularity >= hot[i].popularity).assertTrue();
      }
    });

    it('normalize_and_subscribed_check', 0, () => {
      expect(normalizeFeedKey('https://www.Example.com/feed/')).assertEqual('example.com/feed');
      expect(normalizeFeedKey('http://example.com/feed')).assertEqual('example.com/feed');

      const existing: FeedSource[] =
        [new FeedSource('1', 'Example', 'https://example.com/feed/', 'https://example.com')];
      expect(DiscoverService.isSubscribed('http://www.example.com/feed', existing)).assertTrue();
      expect(DiscoverService.isSubscribed('https://example.com/other', existing)).assertFalse();
    });

    it('recommendations_use_topics_and_exclude_subscribed', 0, () => {
      const existing: FeedSource[] = [
        new FeedSource('1', 'The Verge', 'https://www.theverge.com/rss/index.xml', 'https://www.theverge.com'),
        new FeedSource('2', 'Hacker News', 'https://news.ycombinator.com/rss', 'https://news.ycombinator.com')
      ];
      const list = DiscoverService.recommendations(existing, 6);
      expect(list.length > 0).assertTrue();
      expect(list.length <= 6).assertTrue();
      for (let i = 0; i < list.length; i += 1) {
        expect(DiscoverService.isSubscribed(list[i].feedUrl, existing)).assertFalse();
      }
      const empty = DiscoverService.recommendations([], 6);
      expect(empty.length).assertEqual(0);
    });

    it('rsshub_github', 0, () => {
      const list = routeList('https://github.com/openai/openai-node');
      expect(list.length).assertEqual(3);
      expect(routes(list).indexOf('/github/commits/openai/openai-node') >= 0).assertTrue();
      expect(routes(list).indexOf('/github/releases/openai/openai-node') >= 0).assertTrue();
      expect(routes(list).indexOf('/github/issue/openai/openai-node') >= 0).assertTrue();
      expect(list[0].url.startsWith(DEFAULT_RSSHUB_BASE)).assertTrue();
    });

    it('rsshub_bilibili_youtube_twitter', 0, () => {
      const video = routeList('https://www.bilibili.com/video/BV1xx411c7mD');
      expect(routes(video).indexOf('/bilibili/video/BV1xx411c7mD') >= 0).assertTrue();
      expect(kinds(video).indexOf(RssHubKind.BILIBILI_VIDEO) >= 0).assertTrue();

      const space = routeList('https://space.bilibili.com/123456');
      expect(routes(space).indexOf('/bilibili/user/video/123456') >= 0).assertTrue();

      const channel = routeList('https://www.youtube.com/channel/UCabcdef');
      expect(routes(channel).indexOf('/youtube/channel/UCabcdef') >= 0).assertTrue();

      const handle = routeList('https://www.youtube.com/@someuser');
      expect(routes(handle).indexOf('/youtube/user/someuser') >= 0).assertTrue();

      const twitter = routeList('https://x.com/someuser');
      expect(routes(twitter).indexOf('/twitter/user/someuser') >= 0).assertTrue();
    });

    it('rsshub_weibo_and_unsupported', 0, () => {
      const weibo = routeList('https://weibo.com/u/1234567890');
      expect(routes(weibo).indexOf('/weibo/user/1234567890') >= 0).assertTrue();

      expect(routeList('https://example.com/some/page').length).assertEqual(0);
      expect(routeList('not a url at all').length).assertEqual(0);
    });

    it('rsshub_base_normalization', 0, () => {
      expect(normalizeRssHubBase('')).assertEqual(DEFAULT_RSSHUB_BASE);
      expect(normalizeRssHubBase('rsshub.example.com/')).assertEqual('https://rsshub.example.com');
      expect(normalizeRssHubBase('https://rsshub.example.com/sub/'))
        .assertEqual('https://rsshub.example.com/sub');
      expect(normalizeRssHubBase('   ')).assertEqual(DEFAULT_RSSHUB_BASE);
    });
  });
}
