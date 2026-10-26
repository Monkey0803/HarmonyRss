/*
 * DiscoverService.ets — 「发现」页的纯逻辑：分类 / 关键词筛选、已订阅判定与本地相似源推荐。
 *
 * 不发起任何网络请求，也不写库；视图只调用这些纯函数，便于单测。
 */

import { url } from '@kit.ArkTS';
import { FeedSource } from '../model/Feed';
import { DiscoverCatalog, DiscoverCategory, DiscoverFeed } from '../model/Discover';

/** 用于「相似源」主题识别的固定标签表（与内置目录保持一致）。 */
const TAG_VOCAB: string[] = [
  'tech', 'design', 'business', 'science', 'indie', 'cn',
  'dev', 'news', 'ai', 'productivity', 'community', 'research',
  'culture', 'web', 'ux', 'startup', 'management', 'apple'
];

/** 推荐候选：目录条目 + 匹配分（只用于排序，不对外展示）。 */
class ScoredFeed {
  readonly feed: DiscoverFeed;
  readonly score: number;

  constructor(feed: DiscoverFeed, score: number) {
    this.feed = feed;
    this.score = score;
  }
}

/** 解析地址的主机名；失败返回空串。 */
function hostOf(raw: string): string {
  const trimmed: string = raw.trim();
  if (trimmed.length === 0) {
    return '';
  }
  try {
    return new url.URL(trimmed).hostname.toLowerCase();
  } catch (err) {
    return '';
  }
}

/**
 * 归一化订阅地址，用于「是否已订阅」比较：
 * 忽略 scheme / www / 末尾斜杠 / 锚点 / 大小写主机名，保留路径与查询（部分 feed 靠查询区分）。
 */
export function normalizeFeedKey(raw: string): string {
  const value: string = raw.trim();
  if (value.length === 0) {
    return '';
  }
  try {
    const parsed: url.URL = new url.URL(value);
    let host: string = parsed.hostname.toLowerCase();
    if (host.startsWith('www.')) {
      host = host.substring(4);
    }
    let path: string = parsed.pathname;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return host + path + parsed.search;
  } catch (err) {
    return value.toLowerCase();
  }
}

/** 站点展示名（去 www），用于卡片副标题。 */
export function displayHost(siteUrl: string, feedUrl: string): string {
  const source: string = siteUrl.length > 0 ? siteUrl : feedUrl;
  let host: string = hostOf(source);
  if (host.startsWith('www.')) {
    host = host.substring(4);
  }
  return host;
}

export class DiscoverService {
  /** 目录全部条目。 */
  static all(): DiscoverFeed[] {
    return DiscoverCatalog.FEEDS;
  }

  /** 某分类（或「全部」/「热门」）+ 关键词下的目录。 */
  static filter(category: string, keyword: string): DiscoverFeed[] {
    const query: string = keyword.trim().toLowerCase();
    const result: DiscoverFeed[] = [];
    for (let i = 0; i < DiscoverCatalog.FEEDS.length; i += 1) {
      const feed: DiscoverFeed = DiscoverCatalog.FEEDS[i];
      if (!DiscoverService.inCategory(feed, category)) {
        continue;
      }
      if (query.length > 0 && !DiscoverService.matchesKeyword(feed, query)) {
        continue;
      }
      result.push(feed);
    }
    if (category === DiscoverCategory.HOT) {
      result.sort((a: DiscoverFeed, b: DiscoverFeed) => b.popularity - a.popularity);
    }
    return result;
  }

  /** 分类命中：主题分类按主分类或标签匹配；all / hot 全收。 */
  private static inCategory(feed: DiscoverFeed, category: string): boolean {
    if (category.length === 0 || category === DiscoverCategory.ALL || category === DiscoverCategory.HOT) {
      return true;
    }
    if (feed.category === category) {
      return true;
    }
    return feed.tags.indexOf(category) >= 0;
  }

  private static matchesKeyword(feed: DiscoverFeed, query: string): boolean {
    if (feed.title.toLowerCase().indexOf(query) >= 0) {
      return true;
    }
    if (feed.feedUrl.toLowerCase().indexOf(query) >= 0) {
      return true;
    }
    if (feed.siteUrl.toLowerCase().indexOf(query) >= 0) {
      return true;
    }
    for (let i = 0; i < feed.tags.length; i += 1) {
      if (feed.tags[i].indexOf(query) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 该地址是否已在本地订阅列表中（归一化比较）。 */
  static isSubscribed(feedUrl: string, existing: FeedSource[]): boolean {
    const key: string = normalizeFeedKey(feedUrl);
    if (key.length === 0) {
      return false;
    }
    for (let i = 0; i < existing.length; i += 1) {
      if (normalizeFeedKey(existing[i].url) === key) {
        return true;
      }
    }
    return false;
  }

  /**
   * 「相似源」推荐：根据已订阅源的主题标签打分，排除已订阅项。
   * 命中标签数越多分越高；同分按本地热度。没有任何主题信号时返回空数组（不硬推）。
   */
  static recommendations(existing: FeedSource[], limit: number): DiscoverFeed[] {
    if (limit <= 0) {
      return [];
    }
    const interests: Set<string> = DiscoverService.interestsOf(existing);
    if (interests.size === 0) {
      return [];
    }
    const scored: ScoredFeed[] = [];
    for (let i = 0; i < DiscoverCatalog.FEEDS.length; i += 1) {
      const feed: DiscoverFeed = DiscoverCatalog.FEEDS[i];
      if (DiscoverService.isSubscribed(feed.feedUrl, existing)) {
        continue;
      }
      let overlap: number = 0;
      for (let j = 0; j < feed.tags.length; j += 1) {
        if (interests.has(feed.tags[j])) {
          overlap += 1;
        }
      }
      if (overlap > 0) {
        scored.push(new ScoredFeed(feed, overlap * 100 + feed.popularity));
      }
    }
    scored.sort((a: ScoredFeed, b: ScoredFeed) => b.score - a.score);
    const result: DiscoverFeed[] = [];
    for (let i = 0; i < scored.length && i < limit; i += 1) {
      result.push(scored[i].feed);
    }
    return result;
  }

  /** 从已订阅源推断主题集合：目录命中则取其标签，同时扫描标题 / 地址里的固定标签词。 */
  private static interestsOf(existing: FeedSource[]): Set<string> {
    const interests: Set<string> = new Set();
    for (let i = 0; i < existing.length; i += 1) {
      const source: FeedSource = existing[i];
      const sourceKey: string = normalizeFeedKey(source.url);
      for (let j = 0; j < DiscoverCatalog.FEEDS.length; j += 1) {
        const catalogFeed: DiscoverFeed = DiscoverCatalog.FEEDS[j];
        if (normalizeFeedKey(catalogFeed.feedUrl) === sourceKey) {
          for (let k = 0; k < catalogFeed.tags.length; k += 1) {
            interests.add(catalogFeed.tags[k]);
          }
        }
      }
      const haystack: string = (source.title + ' ' + source.url + ' ' + source.siteUrl).toLowerCase();
      for (let j = 0; j < TAG_VOCAB.length; j += 1) {
        if (haystack.indexOf(TAG_VOCAB[j]) >= 0) {
          interests.add(TAG_VOCAB[j]);
        }
      }
    }
    return interests;
  }
}
