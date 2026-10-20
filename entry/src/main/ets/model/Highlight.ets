/*
 * Highlight.ets — 正文标注（高亮 + 备注）的数据模型。
 *
 * 只存本地（无后端）：一条标注属于一篇文章，带引文（用于在正文里定位）、可选备注与配色。
 * anchorRatio 是定位兜底：引文在纯文本里找不到时（正文变了 / 提取结果不同），
 * 至少还能按「大致在文章的哪个位置」跳过去。
 */

/** 可选配色（语义 id，落到 CSS 类名）。 */
export class HighlightColor {
  static readonly YELLOW: string = 'yellow';
  static readonly GREEN: string = 'green';
  static readonly BLUE: string = 'blue';
  static readonly PINK: string = 'pink';
}

@ObservedV2
export class Highlight {
  readonly id: string;
  readonly articleId: string;
  /** 被高亮的引文（原文片段）。 */
  @Trace quote: string;
  /** 备注（可为空）。 */
  @Trace note: string;
  /** 配色语义 id。 */
  @Trace color: string;
  readonly createdAt: number;
  /** 引文前后的上下文（提高重复引文的定位准确度；可为空）。 */
  readonly anchorText: string;
  /** 位置比例（0–1）：引文定位失败时的兜底跳转锚点。 */
  readonly anchorRatio: number;

  constructor(id: string, articleId: string, quote: string, note: string, color: string,
    createdAt: number, anchorText: string = '', anchorRatio: number = 0) {
    this.id = id;
    this.articleId = articleId;
    this.quote = quote;
    this.note = note;
    this.color = color;
    this.createdAt = createdAt;
    this.anchorText = anchorText;
    this.anchorRatio = anchorRatio;
  }
}

/**
 * 聚合页用的一条标注：标注本体 + 所属文章信息（标题 / 链接 / 来源）。
 * 单独一个类型是因为它来自 JOIN 查询，不是纯粹的一条 highlights 记录。
 */
export class HighlightLibraryItem {
  readonly highlight: Highlight;
  readonly articleTitle: string;
  readonly articleLink: string;
  readonly feedTitle: string;

  constructor(highlight: Highlight, articleTitle: string, articleLink: string, feedTitle: string) {
    this.highlight = highlight;
    this.articleTitle = articleTitle;
    this.articleLink = articleLink;
    this.feedTitle = feedTitle;
  }
}
