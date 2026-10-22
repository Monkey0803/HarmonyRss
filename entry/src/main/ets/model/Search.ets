/*
 * Search.ets — 全文检索与存储统计的领域模型（纯数据结构，不含行为）。
 *
 * SearchQuery 由 SearchQueryParser 解析出来（纯函数），交给 ArticleStore 翻译成 SQL；
 * 视图只消费 SearchHit / SearchPage / StorageStats，不接触 SQL。
 */

/** 检索的状态过滤值（`is:` 语法）。 */
export class SearchState {
  static readonly ALL: string = 'all';
  static readonly UNREAD: string = 'unread';
  static readonly READ: string = 'read';
  static readonly STARRED: string = 'starred';
  static readonly SAVED: string = 'saved';
}

/** ACL：把任意取值归一成受支持的状态值（脏值退回 all）。 */
export function normalizeSearchState(value: string): string {
  if (value === SearchState.UNREAD || value === SearchState.READ ||
    value === SearchState.STARRED || value === SearchState.SAVED) {
    return value;
  }
  return SearchState.ALL;
}

/** 一次检索的解析结果：关键词 + 过滤条件。 */
export class SearchQuery {
  /** 普通关键词（已按空白切分，全部为 AND 关系）。 */
  terms: string[] = [];
  /** 引号短语（整体匹配，优先于 terms）。 */
  phrase: string = '';
  /** `from:` 来源过滤（空串表示不限）。 */
  from: string = '';
  /** 状态过滤：all / unread / read / starred / saved。 */
  state: string = SearchState.ALL;
  /** 发布时间下界（毫秒，0 表示不限）。 */
  after: number = 0;
  /** 发布时间上界（毫秒，0 表示不限）。 */
  before: number = 0;
  /** 用户原始输入（记入搜索历史）。 */
  raw: string = '';

  constructor(raw: string = '') {
    this.raw = raw;
  }
}

/** 一条检索命中。 */
export class SearchHit {
  readonly articleId: string;
  readonly title: string;
  /** 命中片段（已裁切，原文，不做标记）。 */
  readonly snippet: string;
  readonly feedTitle: string;
  readonly publishedAt: number;
  readonly read: boolean;
  readonly starred: boolean;
  readonly saved: boolean;

  constructor(articleId: string, title: string, snippet: string, feedTitle: string,
    publishedAt: number, read: boolean, starred: boolean, saved: boolean) {
    this.articleId = articleId;
    this.title = title;
    this.snippet = snippet;
    this.feedTitle = feedTitle;
    this.publishedAt = publishedAt;
    this.read = read;
    this.starred = starred;
    this.saved = saved;
  }
}

/** 一页检索结果。 */
export class SearchPage {
  readonly hits: SearchHit[];
  readonly total: number;
  readonly hasMore: boolean;

  constructor(hits: SearchHit[], total: number, hasMore: boolean) {
    this.hits = hits;
    this.total = total;
    this.hasMore = hasMore;
  }

  static empty(): SearchPage {
    return new SearchPage([], 0, false);
  }
}

/**
 * 检索索引的诊断快照（存储页「检索索引」分组展示）。
 *
 * 全部是内存态：分词能力每次启动重新探测，条数在重建 / 检索后刷新，不落盘。
 */
export class SearchDiagnostics {
  /** 主 FTS 索引是否可用。 */
  readonly mainIndexReady: boolean;
  /** 中文二元组索引是否可用（false = 中文检索降级为 LIKE）。 */
  readonly cjkIndexReady: boolean;
  /** 设备中文分词能力（启动探针结论：文本 MATCH 是否真的可用）。 */
  readonly cjkFtsCapable: boolean;
  /** 主索引条数。 */
  readonly mainIndexed: number;
  /** 中文索引条数。 */
  readonly cjkIndexed: number;
  /** 最近一次检索走的路径：fts / cjk / like；空串表示本次启动还没检索过。 */
  readonly lastPath: string;
  /** 最近一次检索耗时（毫秒）。 */
  readonly lastMillis: number;

  constructor(mainIndexReady: boolean, cjkIndexReady: boolean, cjkFtsCapable: boolean,
    mainIndexed: number, cjkIndexed: number, lastPath: string, lastMillis: number) {
    this.mainIndexReady = mainIndexReady;
    this.cjkIndexReady = cjkIndexReady;
    this.cjkFtsCapable = cjkFtsCapable;
    this.mainIndexed = mainIndexed;
    this.cjkIndexed = cjkIndexed;
    this.lastPath = lastPath;
    this.lastMillis = lastMillis;
  }

  static empty(): SearchDiagnostics {
    return new SearchDiagnostics(false, false, false, 0, 0, '', 0);
  }
}

/**
 * 一次中文查询的编译结果（纯数据，便于单测）。
 *
 * expression 直接送进 `MATCH`（每个 token 都已转义）；postFilters 是需要在候选集上
 * 再做子串 / 大小写复核的原词（多字中文防止二元组不连续误召回，英文片段补大小写不敏感匹配）。
 */
export class CjkQueryPlan {
  /** 送入 MATCH 的表达式（空串表示没有可用的索引 token）。 */
  readonly expression: string;
  /** 需要在候选集上追加复核的关键词（原词，SQL 里绑参数，不拼串）。 */
  readonly postFilters: string[];
  /** 是否真的能走中文索引。 */
  readonly used: boolean;

  constructor(expression: string, postFilters: string[], used: boolean) {
    this.expression = expression;
    this.postFilters = postFilters;
    this.used = used;
  }

  static none(): CjkQueryPlan {
    return new CjkQueryPlan('', [], false);
  }
}

/** 按订阅源的占用统计。 */
export class FeedStorageStat {
  readonly feedId: string;
  readonly title: string;
  readonly count: number;
  readonly bytes: number;

  constructor(feedId: string, title: string, count: number, bytes: number) {
    this.feedId = feedId;
    this.title = title;
    this.count = count;
    this.bytes = bytes;
  }
}

/** 存储与保留页的统计快照。 */
export class StorageStats {
  /** 本地文章总条数。 */
  readonly articleCount: number;
  /** 正文文本占用（字符数：reader_html + content_html + plain_text）。 */
  readonly textBytes: number;
  /** 按源占用（条数倒序）。 */
  readonly perFeed: FeedStorageStat[];
  /** 当前保留策略下可清理的条数（已排除收藏 / 稍后读 / 有高亮 / 当前文章）。 */
  readonly cleanableCount: number;
  /** 回收站条数（7 天内可恢复）。 */
  readonly trashCount: number;

  constructor(articleCount: number, textBytes: number, perFeed: FeedStorageStat[],
    cleanableCount: number, trashCount: number) {
    this.articleCount = articleCount;
    this.textBytes = textBytes;
    this.perFeed = perFeed;
    this.cleanableCount = cleanableCount;
    this.trashCount = trashCount;
  }

  static empty(): StorageStats {
    return new StorageStats(0, 0, [], 0, 0);
  }
}

/** 保留清理候选（只带定位所需的最小信息）。 */
export class RetentionCandidate {
  readonly id: string;
  readonly feedId: string;
  readonly publishedAt: number;
  /** 是否已读（「仅保留未读」模式只清理已读文章）。 */
  readonly read: boolean;

  constructor(id: string, feedId: string, publishedAt: number, read: boolean = false) {
    this.id = id;
    this.feedId = feedId;
    this.publishedAt = publishedAt;
    this.read = read;
  }
}

/**
 * 保留清理的判定规则（纯函数，便于单测）。
 *
 * 保护条件（满足任意一条永不删除）：收藏、稍后读、存在高亮、当前打开的文章。
 * 清理条件：按天数（发布超过 N 天）或「仅保留未读与收藏」（只清理已读）。
 */
export class RetentionPolicy {
  static readonly DAY_MS: number = 24 * 60 * 60 * 1000;

  /** 是否受保护（永不清理）。 */
  static isProtected(starred: boolean, saved: boolean, highlightCount: number,
    currentId: string, articleId: string): boolean {
    if (starred || saved || highlightCount > 0) {
      return true;
    }
    return currentId.length > 0 && currentId === articleId;
  }

  /** 按天数清理判定：effectiveDays <= 0 表示永久保留；发布时间缺失（0）保守视为不清理。 */
  static isOlderThan(publishedAt: number, effectiveDays: number, now: number): boolean {
    if (publishedAt <= 0 || effectiveDays <= 0) {
      return false;
    }
    return now - publishedAt > effectiveDays * RetentionPolicy.DAY_MS;
  }

  /** 「仅保留未读与收藏」模式下，已读文章才可清理。 */
  static isUnreadModeCandidate(read: boolean): boolean {
    return read;
  }
}
