/*
 * Feed.ets — RSS 阅读器的领域模型（ArkTS 状态管理 V2）。
 *
 * @ObservedV2 + @Trace：字段被界面读取即建立观察关系，因此 ViewModel 直接替换 / 修改这些实例
 * 就能驱动刷新，不必在组件间层层传参。
 */

/** 一个订阅源。 */
@ObservedV2
export class FeedSource {
  /** 唯一标识（用订阅地址，天然去重）。 */
  id: string;
  /** 订阅源标题（解析成功后覆盖为 feed 自身标题）。 */
  @Trace title: string;
  /** 订阅地址（请求用）。 */
  @Trace url: string;
  /** 站点主页（可能为空）。 */
  @Trace siteUrl: string;
  /** 最近一次成功抓取的时间戳（毫秒）。 */
  @Trace lastUpdated: number;
  /** 最近一次抓取到的条目数。 */
  @Trace articleCount: number;
  /** 未读条目数（由 ViewModel 依据缓存计算）。 */
  @Trace unreadCount: number;
  /** 所属分组名；空串表示未分组。 */
  @Trace group: string;
  /** 最近一次抓取的错误描述；空串表示正常。 */
  @Trace lastError: string;
  /**
   * HTTP 条件请求的校验值：上一次响应的 ETag / Last-Modified。
   * 下次抓取带上它们，服务器返回 304 就不用重下整份文档（省流量、省电）。
   * 空串表示该源没提供 / 尚未抓过。
   */
  etag: string = '';
  lastModified: string = '';

  constructor(id: string, title: string, url: string, siteUrl: string, group: string = '') {
    this.id = id;
    this.title = title;
    this.url = url;
    this.siteUrl = siteUrl;
    this.lastUpdated = 0;
    this.articleCount = 0;
    this.unreadCount = 0;
    this.group = group;
    this.lastError = '';
  }
}

/** 一组订阅源（name 为空串表示「未分组」）。 */
export class FeedGroup {
  readonly name: string;
  readonly feeds: FeedSource[];

  constructor(name: string, feeds: FeedSource[]) {
    this.name = name;
    this.feeds = feeds;
  }
}

/**
 * 订阅管理列表的一「行」：分组头 或 订阅源。
 * 分组头行的 feed 是占位对象（只为了让行结构不含可选字段，便于 ArkTS 类型收窄），不参与渲染。
 */
export class FeedListItem {
  readonly isGroup: boolean;
  readonly groupName: string;
  readonly count: number;
  readonly feed: FeedSource;

  constructor(isGroup: boolean, groupName: string, count: number, feed: FeedSource) {
    this.isGroup = isGroup;
    this.groupName = groupName;
    this.count = count;
    this.feed = feed;
  }
}

/** 一篇文章（聚合视图中的条目）。 */
@ObservedV2
export class Article {
  /** 唯一标识：订阅源 id + 链接（或标题）。 */
  id: string;
  /** 所属订阅源 id。 */
  feedId: string;
  /** 所属订阅源标题（冗余保存，便于列表直接展示）。 */
  @Trace feedTitle: string;
  @Trace title: string;
  @Trace link: string;
  /** 纯文本摘要，用于列表。 */
  @Trace summary: string;
  /** 纯文本正文，用于详情兜底 / 搜索。 */
  @Trace content: string;
  /**
   * feed 自带的 HTML 正文（content:encoded / Atom content），保留块级结构，仅做基础清理。
   * 入库后不再变化；有它时可直接提取，无需联网抓原文。
   */
  contentHtml: string;
  /**
   * Reader 视图的结构化正文 HTML（提取 + 净化后的片段）；空串表示尚未生成。
   * 生成后持久化到本地库，离线可读。
   */
  @Trace readerHtml: string;
  /** Reader 提取状态：'none' | 'loading' | 'ready' | 'failed'。 */
  @Trace readerState: string;
  /**
   * Reader 正文的纯文本（由 readerHtml 去标签得到，落库）：
   * 供「搜索命中正文 / 复制正文 / 分享正文 / 朗读」复用，避免每次现算。
   * feed 自带全文（content）仍单独保留，两者都可能为空。
   */
  plainText: string = '';
  /** 正文页的 ETag / Last-Modified（条件请求用：页面没变时服务端回 304，省一次整页下载）。 */
  pageEtag: string = '';
  pageLastModified: string = '';
  /** 发布时间戳（毫秒）；解析不到时为 0。 */
  @Trace publishedAt: number;
  /** 配图地址（网络 URL）；空串表示没有配图。入库后不再变化。 */
  imageUrl: string;
  /** 作者（dc:creator / author / JSON Feed author）；空串表示没有。入库后不再变化。 */
  author: string;
  /** 已读（持久化到本地库）。 */
  @Trace read: boolean;
  /** 收藏 / 稍后读（持久化到本地库）。 */
  @Trace starred: boolean;
  /**
   * 阅读进度：上次读到的滚动位置（px；网页原文与提取正文共用同一个值）。
   * 由详情页写入本地库，重新打开时恢复；0 表示从头开始。
   */
  @Trace progress: number = 0;
  /**
   * 阅读进度比例（0–1）：y / (scrollHeight - innerHeight)。
   * 换字号 / 栏宽 / 主题后排版会重排，px 会漂，恢复位置以比例为准（px 仅作老数据兜底）。
   */
  @Trace progressRatio: number = 0;

  constructor(id: string, feedId: string, feedTitle: string, title: string, link: string,
    summary: string, content: string, publishedAt: number, imageUrl: string = '', author: string = '',
    contentHtml: string = '') {
    this.id = id;
    this.feedId = feedId;
    this.feedTitle = feedTitle;
    this.title = title;
    this.link = link;
    this.summary = summary;
    this.content = content;
    this.contentHtml = contentHtml;
    this.publishedAt = publishedAt;
    this.imageUrl = imageUrl;
    this.author = author;
    this.read = false;
    this.starred = false;
    this.readerHtml = '';
    this.readerState = 'none';
  }
}
