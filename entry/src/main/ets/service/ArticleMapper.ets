/*
 * ArticleMapper.ets — 解析结果 → 领域模型的纯转换。
 *
 * 前台刷新（FeedViewModel）和后台定时抓取（RssWorkScheduler）都要做同一件事，抽出来避免两处各写一份。
 * 已读 / 收藏不在转换里设置：本地库是它们的事实来源（入库时 INSERT OR IGNORE，不会覆盖）。
 */

import { Article, FeedSource } from '../model/Feed';
import { ParsedArticle, ParsedFeed } from './RssParser';
import { ARTICLE_ID_SEPARATOR } from '../common/constants/RssConstants';
import { articleStore } from './ArticleStore';

/** 文章 id：订阅源 id + 链接（没有链接时退化为标题）。 */
export function buildArticleId(feedId: string, item: ParsedArticle): string {
  const key: string = item.link.length > 0 ? item.link : item.title;
  return feedId + ARTICLE_ID_SEPARATOR + key;
}

/** 把一次解析结果转成文章数组，并回填订阅源元信息（标题变化会同步到缓存行）。 */
export function toArticles(feed: FeedSource, parsed: ParsedFeed, sink: Article[]): void {
  if (parsed.title.length > 0 && parsed.title !== feed.title) {
    feed.title = parsed.title;
    articleStore.updateFeedTitle(feed.id, parsed.title);
  }
  if (parsed.siteUrl.length > 0) {
    feed.siteUrl = parsed.siteUrl;
  }
  feed.lastUpdated = Date.now();
  // 同一批里按 id 去重：feed 里偶发重复条目（同一链接出现两次、guid 与 link 混用）时，
  // 本地库虽然有 INSERT OR IGNORE，但内存列表会重复显示，所以先在这里过滤掉。
  const seen: Set<string> = new Set<string>();
  let accepted: number = 0;
  for (let i = 0; i < parsed.articles.length; i += 1) {
    const item: ParsedArticle = parsed.articles[i];
    const id: string = buildArticleId(feed.id, item);
    if (seen.has(id)) {
      continue;
    }
    seen.add(id);
    accepted += 1;
    sink.push(new Article(id, feed.id, feed.title, item.title, item.link,
      item.summary, item.content, item.publishedAt, item.imageUrl, item.author, item.contentHtml));
  }
  feed.articleCount = accepted;
}
