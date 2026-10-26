/*
 * Backup.ets — 备份 / 迁移的数据模型（纯数据，不参与 UI 观察）。
 *
 * 备份文件是版本化 JSON：BackupDocument 聚合各数据段，各段 DTO 只保留恢复所需字段。
 * 这里的类全部显式声明字段与默认值，遵循 ArkTS 严格模式（不用对象字面量当类型）：
 *   - 导出：由领域模型经 BackupCodec.sanitize* 映射成这些 DTO；
 *   - 导入：由 BackupCodec.parse 逐字段收敛后构造，未知字段直接忽略。
 */

import { RssConstants } from '../common/constants/RssConstants';
import { FullTextMode, TriState } from '../common/constants/SettingsConstants';

/** 设置段允许的标量值（白名单键 → 字符串 / 布尔 / 数字）。 */
export type BackupScalar = string | number | boolean;

/**
 * 设置段：一份「键 → 标量」的扁平映射。
 *
 * toJSON 让 JSON.stringify 直接把内容写成 `"settings": { "themeMode": "dark" }`，
 * 而不是多包一层 `{ "values": ... }`，保证备份文件对外结构稳定、可读。
 */
export class BackupSettings {
  /** 白名单设置键值。 */
  values: Record<string, BackupScalar>;

  constructor(values: Record<string, BackupScalar> = {}) {
    this.values = values;
  }

  get(key: string): BackupScalar | undefined {
    return this.values[key];
  }

  set(key: string, value: BackupScalar): void {
    this.values[key] = value;
  }

  has(key: string): boolean {
    return this.values[key] !== undefined;
  }

  keys(): string[] {
    return Object.keys(this.values);
  }

  /** 供 JSON.stringify 直接展开为扁平对象。 */
  toJSON(): Record<string, BackupScalar> {
    return this.values;
  }
}

/** 订阅段：URL、标题、站点、分组与单源设置（不含 ETag / 抓取状态 / 凭据）。 */
export class BackupFeed {
  /** 订阅地址（合并主键）。 */
  url: string;
  title: string;
  siteUrl: string;
  /** 分组名；空串表示未分组。 */
  group: string;
  enabled: boolean;
  /** 抓取间隔（分钟）；0 = 跟随全局。 */
  fetchIntervalMinutes: number;
  /** 全文策略：global / auto / always / never。 */
  fullTextMode: string;
  /** 保留天数；0 = 跟随全局。 */
  retentionDays: number;
  /** 新文章通知：global / on / off。 */
  notify: string;
  /** 滚动即已读：global / on / off。 */
  markReadOnScroll: string;

  constructor(url: string = '', title: string = '', siteUrl: string = '', group: string = '',
    enabled: boolean = true, fetchIntervalMinutes: number = 0,
    fullTextMode: string = FullTextMode.GLOBAL, retentionDays: number = 0,
    notify: string = TriState.GLOBAL, markReadOnScroll: string = TriState.GLOBAL) {
    this.url = url;
    this.title = title;
    this.siteUrl = siteUrl;
    this.group = group;
    this.enabled = enabled;
    this.fetchIntervalMinutes = fetchIntervalMinutes;
    this.fullTextMode = fullTextMode;
    this.retentionDays = retentionDays;
    this.notify = notify;
    this.markReadOnScroll = markReadOnScroll;
  }
}

/**
 * 文章状态（合并决策的最小单元）。
 * 合并规则：read / starred / saved / hidden 取 OR，progress / progressRatio 取 max，
 * canonicalId 保留 existing 非空值（空则取 incoming）。
 */
export class ArticleStatePatch {
  read: boolean;
  starred: boolean;
  saved: boolean;
  hidden: boolean;
  /** 上次阅读滚动位置（px）。 */
  progress: number;
  /** 上次阅读进度比例（0–1）。 */
  progressRatio: number;
  /** 跨源去重主条 id；空串表示自身即主条。 */
  canonicalId: string;

  constructor(read: boolean = false, starred: boolean = false, saved: boolean = false,
    hidden: boolean = false, progress: number = 0, progressRatio: number = 0,
    canonicalId: string = '') {
    this.read = read;
    this.starred = starred;
    this.saved = saved;
    this.hidden = hidden;
    this.progress = progress;
    this.progressRatio = progressRatio;
    this.canonicalId = canonicalId;
  }
}

/**
 * 文章段：仅元数据 + 阅读状态。
 * 不含 content / contentHtml / readerHtml / plainText / pageEtag 等正文缓存，
 * 也不含 duplicateCount 等派生字段；导入后正文在首次打开时重新提取。
 */
export class BackupArticle extends ArticleStatePatch {
  /** 文章 id（合并主键）。 */
  id: string;
  feedId: string;
  feedTitle: string;
  title: string;
  link: string;
  summary: string;
  author: string;
  /** 发布时间戳（毫秒）；0 表示未知。 */
  publishedAt: number;
  imageUrl: string;
  /** 跨源去重 URL 归一化键。 */
  linkKey: string;
  /** 跨源去重标题归一化键。 */
  titleKey: string;

  constructor(id: string = '', feedId: string = '', feedTitle: string = '', title: string = '',
    link: string = '', summary: string = '', author: string = '', publishedAt: number = 0,
    imageUrl: string = '', read: boolean = false, starred: boolean = false,
    saved: boolean = false, hidden: boolean = false, progress: number = 0,
    progressRatio: number = 0, canonicalId: string = '', linkKey: string = '',
    titleKey: string = '') {
    super(read, starred, saved, hidden, progress, progressRatio, canonicalId);
    this.id = id;
    this.feedId = feedId;
    this.feedTitle = feedTitle;
    this.title = title;
    this.link = link;
    this.summary = summary;
    this.author = author;
    this.publishedAt = publishedAt;
    this.imageUrl = imageUrl;
    this.linkKey = linkKey;
    this.titleKey = titleKey;
  }
}

/** 高亮段：文章 id、引文、备注、配色与定位锚点。 */
export class BackupHighlight {
  id: string;
  articleId: string;
  quote: string;
  note: string;
  color: string;
  /** 创建时间戳（毫秒）。 */
  createdAt: number;
  /** 引文前后上下文（定位辅助）。 */
  anchorText: string;
  /** 位置比例（0–1，定位兜底）。 */
  anchorRatio: number;

  constructor(id: string = '', articleId: string = '', quote: string = '', note: string = '',
    color: string = '', createdAt: number = 0, anchorText: string = '',
    anchorRatio: number = 0) {
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

/** 标签段：id / 展示名 / 创建时间（合并时按归一化名称 name_key 去重）。 */
export class BackupTag {
  id: string;
  name: string;
  createdAt: number;

  constructor(id: string = '', name: string = '', createdAt: number = 0) {
    this.id = id;
    this.name = name;
    this.createdAt = createdAt;
  }
}

/** 文章 ↔ 标签关联（联合键 articleId + tagId 去重）。 */
export class BackupArticleTag {
  articleId: string;
  tagId: string;

  constructor(articleId: string = '', tagId: string = '') {
    this.articleId = articleId;
    this.tagId = tagId;
  }
}

/** 智能文件夹段：名称 + 检索语法原始串 + 排序位（按 id 合并）。 */
export class BackupSmartFolder {
  id: string;
  name: string;
  query: string;
  sortOrder: number;

  constructor(id: string = '', name: string = '', query: string = '', sortOrder: number = 0) {
    this.id = id;
    this.name = name;
    this.query = query;
    this.sortOrder = sortOrder;
  }
}

/** 规则段：规则全字段 + 命中统计（按 id 合并）。 */
export class BackupRule {
  id: string;
  name: string;
  enabled: boolean;
  priority: number;
  keywords: string[];
  fields: string[];
  feedIds: string[];
  actions: string[];
  tagIds: string[];
  matchCount: number;
  lastHitAt: number;

  constructor(id: string = '', name: string = '', enabled: boolean = true, priority: number = 0,
    keywords: string[] = [], fields: string[] = [], feedIds: string[] = [],
    actions: string[] = [], tagIds: string[] = [], matchCount: number = 0,
    lastHitAt: number = 0) {
    this.id = id;
    this.name = name;
    this.enabled = enabled;
    this.priority = priority;
    this.keywords = keywords;
    this.fields = fields;
    this.feedIds = feedIds;
    this.actions = actions;
    this.tagIds = tagIds;
    this.matchCount = matchCount;
    this.lastHitAt = lastHitAt;
  }
}

/** 分享模板段：id / 名称 / 模板正文 / 排序位（按 id 合并）。 */
export class BackupTemplate {
  id: string;
  name: string;
  content: string;
  sort: number;

  constructor(id: string = '', name: string = '', content: string = '', sort: number = 0) {
    this.id = id;
    this.name = name;
    this.content = content;
    this.sort = sort;
  }
}

/** 备份根文档：版本 + 导出时间 + 各数据段。 */
export class BackupDocument {
  version: number;
  /** 导出时间戳（毫秒）。 */
  exportedAt: number;
  /** 导出应用标识（便于排查来源）。 */
  app: string;
  feeds: BackupFeed[];
  articles: BackupArticle[];
  highlights: BackupHighlight[];
  tags: BackupTag[];
  articleTags: BackupArticleTag[];
  smartFolders: BackupSmartFolder[];
  rules: BackupRule[];
  templates: BackupTemplate[];
  settings: BackupSettings;

  constructor() {
    this.version = RssConstants.BACKUP_VERSION;
    this.exportedAt = 0;
    this.app = 'HarmonyRss';
    this.feeds = [];
    this.articles = [];
    this.highlights = [];
    this.tags = [];
    this.articleTags = [];
    this.smartFolders = [];
    this.rules = [];
    this.templates = [];
    this.settings = new BackupSettings();
  }
}

/** 一次导入 / 恢复的统计（UI 只展示这些计数，不暴露表名）。 */
export class BackupSummary {
  feedsAdded: number;
  articlesAdded: number;
  articlesUpdated: number;
  highlightsAdded: number;
  tagsAdded: number;
  /** 因依赖缺失 / 无法合并而跳过的条数（不视为失败）。 */
  skipped: number;
  /** 单条写入失败的条数（不中断整次导入）。 */
  failed: number;

  constructor(feedsAdded: number = 0, articlesAdded: number = 0, articlesUpdated: number = 0,
    highlightsAdded: number = 0, tagsAdded: number = 0, skipped: number = 0,
    failed: number = 0) {
    this.feedsAdded = feedsAdded;
    this.articlesAdded = articlesAdded;
    this.articlesUpdated = articlesUpdated;
    this.highlightsAdded = highlightsAdded;
    this.tagsAdded = tagsAdded;
    this.skipped = skipped;
    this.failed = failed;
  }

  static empty(): BackupSummary {
    return new BackupSummary();
  }

  /** 新增总量（订阅 + 文章 + 高亮 + 标签），用于「最近一次结果」摘要行。 */
  totalAdded(): number {
    return this.feedsAdded + this.articlesAdded + this.highlightsAdded + this.tagsAdded;
  }

  hasChanges(): boolean {
    return this.totalAdded() > 0 || this.articlesUpdated > 0;
  }
}

/** 一个本地自动快照的描述（列表展示 + 恢复 / 删除定位）。 */
export class SnapshotInfo {
  /** 文件名（如 harmonyrss-backup-20261026.json）。 */
  fileName: string;
  /** 完整沙箱路径。 */
  path: string;
  /** 文件大小（字节）。 */
  sizeBytes: number;
  /** 创建 / 最后修改时间戳（毫秒）。 */
  createdAt: number;

  constructor(fileName: string = '', path: string = '', sizeBytes: number = 0,
    createdAt: number = 0) {
    this.fileName = fileName;
    this.path = path;
    this.sizeBytes = sizeBytes;
    this.createdAt = createdAt;
  }
}
