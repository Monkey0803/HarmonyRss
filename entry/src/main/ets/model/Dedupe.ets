/*
 * Dedupe.ets — 跨源去重的领域模型。
 *
 * 纯数据类（无副作用、无状态管理装饰器）：只在入库匹配、组展开、来源展示三处流转，
 * 由 service/DedupeKeys（归一化）与 service/DedupeService（匹配 / 组操作）消费。
 */

/** 匹配依据：URL 归一化键相同。 */
export const MATCHED_BY_URL: string = 'url';
/** 匹配依据：标题归一化键相同且在时间窗内。 */
export const MATCHED_BY_TITLE: string = 'title';

/**
 * 去重候选：一篇文章参与匹配所需的全部信息（不含正文，避免大批量匹配时占内存）。
 * canonicalId 为空串表示它是主条；非空表示它已挂在某个主条下（重复项）。
 */
export class DedupeCandidate {
  /** 文章 id（= 订阅源 id + 链接，与 Article.id 一致）。 */
  readonly id: string;
  /** 所属订阅源 id：跨源去重只在 feedId 不同时才生效。 */
  readonly feedId: string;
  /** 主条 id；空串 = 自己是主条。 */
  readonly canonicalId: string;
  /** URL 归一化键（空串 = 该文章没有可用链接，不参与 URL 匹配）。 */
  readonly linkKey: string;
  /** 标题归一化键（空串 = 标题为空，不参与标题匹配）。 */
  readonly titleKey: string;
  /** 发布时间戳（毫秒）；0 = 缺失，标题判定时用入库时间兜底。 */
  readonly publishedAt: number;

  constructor(id: string, feedId: string, canonicalId: string, linkKey: string, titleKey: string,
    publishedAt: number) {
    this.id = id;
    this.feedId = feedId;
    this.canonicalId = canonicalId;
    this.linkKey = linkKey;
    this.titleKey = titleKey;
    this.publishedAt = publishedAt;
  }
}

/** 一次匹配的结果：挂到哪条主条、依据是什么。 */
export class DedupeMatch {
  /** 命中的主条（根）id。 */
  readonly canonicalId: string;
  /** 匹配依据：MATCHED_BY_URL / MATCHED_BY_TITLE。 */
  readonly matchedBy: string;

  constructor(canonicalId: string, matchedBy: string) {
    this.canonicalId = canonicalId;
    this.matchedBy = matchedBy;
  }
}

/**
 * 合并组里的一个来源（详情页来源区展示用）。
 * 只需要「哪一篇 / 哪个源 / 什么链接 / 什么时候发」，不需要正文。
 */
export class GroupSource {
  /** 该来源对应的文章 id。 */
  readonly articleId: string;
  /** 订阅源标题（展示名）。 */
  readonly feedTitle: string;
  /** 原文链接（点击打开）。 */
  readonly link: string;
  /** 发布时间戳（毫秒）；0 = 未知。 */
  readonly publishedAt: number;

  constructor(articleId: string, feedTitle: string, link: string, publishedAt: number) {
    this.articleId = articleId;
    this.feedTitle = feedTitle;
    this.link = link;
    this.publishedAt = publishedAt;
  }
}
