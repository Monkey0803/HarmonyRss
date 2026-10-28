/*
 * Discover.ets — 「发现与推荐」的领域模型与本地精选目录。
 *
 * 目录完全内置（无网络请求）：分类、标签、热度只用于本地筛选与排序，
 * 真正的抓取只会在用户点击「订阅」时发生（复用既有 addFeed 链路）。
 */

/** 发现页分类 / 主题的语义 id（与界面文案解耦，便于单测）。 */
export class DiscoverCategory {
  static readonly ALL: string = 'all';
  /** 本地热度榜（按 popularity 排序，不联网）。 */
  static readonly HOT: string = 'hot';
  static readonly TECH: string = 'tech';
  static readonly DESIGN: string = 'design';
  static readonly BUSINESS: string = 'business';
  static readonly SCIENCE: string = 'science';
  static readonly INDIE: string = 'indie';
  static readonly CN: string = 'cn';
  /** 界面展示顺序（all / hot 之外的主题）。 */
  static readonly TOPICS: string[] = [
    DiscoverCategory.TECH,
    DiscoverCategory.DESIGN,
    DiscoverCategory.BUSINESS,
    DiscoverCategory.SCIENCE,
    DiscoverCategory.INDIE,
    DiscoverCategory.CN
  ];
}

/** 一条精选订阅源。 */
export class DiscoverFeed {
  readonly title: string;
  readonly feedUrl: string;
  readonly siteUrl: string;
  /** 主分类（DiscoverCategory 的 id）。 */
  readonly category: string;
  /** 主题标签：既用于跨分类筛选，也用于「相似源」推荐。 */
  readonly tags: string[];
  /** 0–100 的本地热度（人工维护的固定值，不联网、不随使用变化）。 */
  readonly popularity: number;

  constructor(title: string, feedUrl: string, siteUrl: string,
    category: string, tags: string[], popularity: number) {
    this.title = title;
    this.feedUrl = feedUrl;
    this.siteUrl = siteUrl;
    this.category = category;
    this.tags = tags;
    this.popularity = popularity;
  }
}

/**
 * 内置精选目录。
 *
 * 说明：这里只收录公开、长期稳定提供 RSS / Atom / JSON Feed 的站点；
 * 地址写死而非运行时探测，保证「发现」页离线可用、不产生任何后台请求。
 */
export class DiscoverCatalog {
  static readonly FEEDS: DiscoverFeed[] = [
    // ---- 科技 ----
    new DiscoverFeed('The Verge', 'https://www.theverge.com/rss/index.xml',
      'https://www.theverge.com', DiscoverCategory.TECH, ['tech', 'news'], 96),
    new DiscoverFeed('Hacker News', 'https://news.ycombinator.com/rss',
      'https://news.ycombinator.com', DiscoverCategory.TECH, ['tech', 'community'], 95),
    new DiscoverFeed('Ars Technica', 'https://feeds.arstechnica.com/arstechnica/index',
      'https://arstechnica.com', DiscoverCategory.TECH, ['tech', 'research'], 90),
    new DiscoverFeed('TechCrunch', 'https://techcrunch.com/feed/',
      'https://techcrunch.com', DiscoverCategory.TECH, ['tech', 'startup'], 82),
    new DiscoverFeed('Wired', 'https://www.wired.com/feed/rss',
      'https://www.wired.com', DiscoverCategory.TECH, ['tech', 'culture'], 80),
    new DiscoverFeed('MIT Technology Review', 'https://www.technologyreview.com/feed/',
      'https://www.technologyreview.com', DiscoverCategory.TECH, ['tech', 'research'], 78),
    new DiscoverFeed('Hacker Noon', 'https://hackernoon.com/feed',
      'https://hackernoon.com', DiscoverCategory.TECH, ['tech', 'dev'], 60),
    // ---- 设计 ----
    new DiscoverFeed('Smashing Magazine', 'https://www.smashingmagazine.com/feed/',
      'https://www.smashingmagazine.com', DiscoverCategory.DESIGN, ['design', 'web'], 75),
    new DiscoverFeed('Nielsen Norman Group', 'https://www.nngroup.com/feed/rss/',
      'https://www.nngroup.com', DiscoverCategory.DESIGN, ['design', 'ux', 'research'], 72),
    new DiscoverFeed('UX Collective', 'https://uxdesign.cc/feed',
      'https://uxdesign.cc', DiscoverCategory.DESIGN, ['design', 'ux'], 70),
    new DiscoverFeed('A List Apart', 'https://alistapart.com/main/feed/',
      'https://alistapart.com', DiscoverCategory.DESIGN, ['design', 'web'], 65),
    // ---- 商业 ----
    new DiscoverFeed('Harvard Business Review', 'https://feeds.hbr.org/harvardbusiness',
      'https://hbr.org', DiscoverCategory.BUSINESS, ['business', 'management'], 74),
    new DiscoverFeed('Fast Company', 'https://www.fastcompany.com/rss',
      'https://www.fastcompany.com', DiscoverCategory.BUSINESS, ['business', 'culture'], 60),
    new DiscoverFeed('36氪', 'https://36kr.com/feed',
      'https://36kr.com', DiscoverCategory.CN, ['cn', 'business', 'startup', 'tech'], 80),
    new DiscoverFeed('虎嗅', 'https://www.huxiu.com/rss/0.xml',
      'https://www.huxiu.com', DiscoverCategory.CN, ['cn', 'business', 'tech'], 76),
    // ---- 科学 ----
    new DiscoverFeed('Nature', 'https://www.nature.com/nature.rss',
      'https://www.nature.com', DiscoverCategory.SCIENCE, ['science', 'research'], 85),
    new DiscoverFeed('Quanta Magazine', 'https://www.quantamagazine.org/feed/',
      'https://www.quantamagazine.org', DiscoverCategory.SCIENCE, ['science', 'research'], 78),
    new DiscoverFeed('Scientific American', 'https://www.scientificamerican.com/feed/',
      'https://www.scientificamerican.com', DiscoverCategory.SCIENCE, ['science'], 72),
    new DiscoverFeed('ScienceDaily', 'https://www.sciencedaily.com/rss/all.xml',
      'https://www.sciencedaily.com', DiscoverCategory.SCIENCE, ['science'], 60),
    // ---- 独立博客 ----
    new DiscoverFeed('Daring Fireball', 'https://daringfireball.net/feeds/main',
      'https://daringfireball.net', DiscoverCategory.INDIE, ['indie', 'apple', 'tech'], 82),
    new DiscoverFeed('Simon Willison', 'https://simonwillison.net/atom/everything/',
      'https://simonwillison.net', DiscoverCategory.INDIE, ['indie', 'dev', 'ai'], 76),
    new DiscoverFeed('Julia Evans', 'https://jvns.ca/atom.xml',
      'https://jvns.ca', DiscoverCategory.INDIE, ['indie', 'dev'], 70),
    new DiscoverFeed('Kottke', 'https://feeds.kottke.org/main',
      'https://kottke.org', DiscoverCategory.INDIE, ['indie', 'culture'], 65),
    new DiscoverFeed('Brent Simmons', 'https://inessential.com/feed.json',
      'https://inessential.com', DiscoverCategory.INDIE, ['indie', 'apple', 'dev'], 58),
    // ---- 中文 ----
    new DiscoverFeed('少数派', 'https://sspai.com/feed',
      'https://sspai.com', DiscoverCategory.CN, ['cn', 'tech', 'productivity'], 88),
    new DiscoverFeed('阮一峰的网络日志', 'https://www.ruanyifeng.com/blog/atom.xml',
      'https://www.ruanyifeng.com', DiscoverCategory.CN, ['cn', 'dev', 'indie'], 85),
    new DiscoverFeed('V2EX', 'https://www.v2ex.com/index.xml',
      'https://www.v2ex.com', DiscoverCategory.CN, ['cn', 'tech', 'community'], 72),
    new DiscoverFeed('Hacker News 中文', 'https://hn.buzzing.cc/feed.xml',
      'https://hn.buzzing.cc', DiscoverCategory.CN, ['cn', 'tech', 'community'], 74),
    new DiscoverFeed('酷 壳', 'https://coolshell.cn/feed',
      'https://coolshell.cn', DiscoverCategory.CN, ['cn', 'dev', 'indie'], 70),
    new DiscoverFeed('爱范儿', 'https://www.ifanr.com/feed',
      'https://www.ifanr.com', DiscoverCategory.CN, ['cn', 'tech'], 65),
    new DiscoverFeed('极客公园', 'https://www.geekpark.net/rss',
      'https://www.geekpark.net', DiscoverCategory.CN, ['cn', 'tech', 'startup'], 62)
  ];
}
