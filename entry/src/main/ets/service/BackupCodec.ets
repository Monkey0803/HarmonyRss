/*
 * BackupCodec.ets — 备份文件的序列化 / 解析 / 合并决策（纯逻辑，无 IO，便于单测）。
 *
 * 职责边界：
 *   - serialize：把 BackupDocument 变成版本化 JSON；
 *   - parse：JSON → 严格模型，版本必须匹配，数组缺失给空数组，字段按类型收敛，未知字段忽略；
 *   - mergeArticleState：导入时的状态并集（读 / 收藏 / 稍后读 / 隐藏 OR，进度 max）；
 *   - settingsWhitelist / isSettingsKeyAllowed：设置段白名单（不含设备路径与凭据）；
 *   - sanitizeFeed / sanitizeArticle：导出时只挑恢复所需字段，剔除正文缓存、ETag 等。
 *
 * 所有函数失败时返回空值 / undefined，不向调用方抛异常。
 */

import {
  ArticleStatePatch,
  BackupArticle,
  BackupArticleTag,
  BackupDocument,
  BackupFeed,
  BackupHighlight,
  BackupRule,
  BackupScalar,
  BackupSettings,
  BackupSmartFolder,
  BackupTag,
  BackupTemplate
} from '../model/Backup';
import { RssConstants } from '../common/constants/RssConstants';
import { FullTextMode, TriState } from '../common/constants/SettingsConstants';
import { isPresent, isSettingsKeyAllowed } from './BackupPolicy';

// ---- JSON 原始结构（宽松，全部可选；parse 后逐字段收敛） ----

interface BackupFeedRaw {
  url?: BackupScalar;
  title?: BackupScalar;
  siteUrl?: BackupScalar;
  group?: BackupScalar;
  enabled?: BackupScalar;
  fetchIntervalMinutes?: BackupScalar;
  fullTextMode?: BackupScalar;
  retentionDays?: BackupScalar;
  notify?: BackupScalar;
  markReadOnScroll?: BackupScalar;
}

interface BackupArticleRaw {
  id?: BackupScalar;
  feedId?: BackupScalar;
  feedTitle?: BackupScalar;
  title?: BackupScalar;
  link?: BackupScalar;
  summary?: BackupScalar;
  author?: BackupScalar;
  publishedAt?: BackupScalar;
  imageUrl?: BackupScalar;
  read?: BackupScalar;
  starred?: BackupScalar;
  saved?: BackupScalar;
  hidden?: BackupScalar;
  progress?: BackupScalar;
  progressRatio?: BackupScalar;
  canonicalId?: BackupScalar;
  linkKey?: BackupScalar;
  titleKey?: BackupScalar;
}

interface BackupHighlightRaw {
  id?: BackupScalar;
  articleId?: BackupScalar;
  quote?: BackupScalar;
  note?: BackupScalar;
  color?: BackupScalar;
  createdAt?: BackupScalar;
  anchorText?: BackupScalar;
  anchorRatio?: BackupScalar;
}

interface BackupTagRaw {
  id?: BackupScalar;
  name?: BackupScalar;
  createdAt?: BackupScalar;
}

interface BackupArticleTagRaw {
  articleId?: BackupScalar;
  tagId?: BackupScalar;
}

interface BackupSmartFolderRaw {
  id?: BackupScalar;
  name?: BackupScalar;
  query?: BackupScalar;
  sortOrder?: BackupScalar;
}

interface BackupRuleRaw {
  id?: BackupScalar;
  name?: BackupScalar;
  enabled?: BackupScalar;
  priority?: BackupScalar;
  keywords?: BackupScalar[];
  fields?: BackupScalar[];
  feedIds?: BackupScalar[];
  actions?: BackupScalar[];
  tagIds?: BackupScalar[];
  matchCount?: BackupScalar;
  lastHitAt?: BackupScalar;
}

interface BackupTemplateRaw {
  id?: BackupScalar;
  name?: BackupScalar;
  content?: BackupScalar;
  sort?: BackupScalar;
}

interface BackupDocumentRaw {
  version?: BackupScalar;
  exportedAt?: BackupScalar;
  app?: BackupScalar;
  feeds?: BackupFeedRaw[];
  articles?: BackupArticleRaw[];
  highlights?: BackupHighlightRaw[];
  tags?: BackupTagRaw[];
  articleTags?: BackupArticleTagRaw[];
  smartFolders?: BackupSmartFolderRaw[];
  rules?: BackupRuleRaw[];
  templates?: BackupTemplateRaw[];
  settings?: Record<string, BackupScalar>;
}

// ---- 字段收敛辅助（非法 / 缺失一律回默认值） ----

function textOf(value: BackupScalar | undefined): string {
  return typeof value === 'string' ? value : '';
}

/** 字符串字段：空串视为缺失，回落到默认值（避免旧备份把枚举字段清空）。 */
function textOr(value: BackupScalar | undefined, fallback: string): string {
  const text: string = textOf(value);
  return text.length > 0 ? text : fallback;
}

function numberOf(value: BackupScalar | undefined): number {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : 0;
  }
  if (typeof value === 'string') {
    const parsed: number = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

/** 非负整数（抓取间隔 / 保留天数等）：负数、小数、非法值都收敛到 0。 */
function nonNegativeInt(value: BackupScalar | undefined): number {
  const parsed: number = numberOf(value);
  if (parsed <= 0) {
    return 0;
  }
  return Math.floor(parsed);
}

function booleanOf(value: BackupScalar | undefined, fallback: boolean): boolean {
  if (value === undefined) {
    return fallback;
  }
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'number') {
    return value !== 0;
  }
  const normalized: string = value.trim().toLowerCase();
  return normalized === 'true' || normalized === '1';
}

/** 字符串数组：只保留 string 元素（数字 / null / 嵌套对象一律丢弃）。 */
function stringListOf(value: BackupScalar[] | undefined): string[] {
  const result: string[] = [];
  if (value === undefined || !Array.isArray(value)) {
    return result;
  }
  for (let i = 0; i < value.length; i += 1) {
    const item: BackupScalar = value[i];
    if (typeof item === 'string') {
      result.push(item);
    }
  }
  return result;
}

/** 空文本判定（合并键有效性）。 */
function parseFeeds(items: BackupFeedRaw[] | undefined): BackupFeed[] {
  const result: BackupFeed[] = [];
  if (items === undefined || !Array.isArray(items)) {
    return result;
  }
  for (let i = 0; i < items.length; i += 1) {
    try {
      const item: BackupFeedRaw = items[i];
      const url: string = textOf(item.url);
      if (!isPresent(url)) {
        continue;
      }
      result.push(new BackupFeed(url, textOf(item.title), textOf(item.siteUrl), textOf(item.group),
        booleanOf(item.enabled, true), nonNegativeInt(item.fetchIntervalMinutes),
        textOr(item.fullTextMode, FullTextMode.GLOBAL), nonNegativeInt(item.retentionDays),
        textOr(item.notify, TriState.GLOBAL), textOr(item.markReadOnScroll, TriState.GLOBAL)));
    } catch (err) {
      // 单条脏数据不影响整份备份：跳过即可，由导入统计兜底。
      continue;
    }
  }
  return result;
}

function parseArticles(items: BackupArticleRaw[] | undefined): BackupArticle[] {
  const result: BackupArticle[] = [];
  if (items === undefined || !Array.isArray(items)) {
    return result;
  }
  for (let i = 0; i < items.length; i += 1) {
    try {
      const item: BackupArticleRaw = items[i];
      const id: string = textOf(item.id);
      if (!isPresent(id)) {
        continue;
      }
      result.push(new BackupArticle(id, textOf(item.feedId), textOf(item.feedTitle),
        textOf(item.title), textOf(item.link), textOf(item.summary), textOf(item.author),
        numberOf(item.publishedAt), textOf(item.imageUrl), booleanOf(item.read, false),
        booleanOf(item.starred, false), booleanOf(item.saved, false),
        booleanOf(item.hidden, false), numberOf(item.progress), numberOf(item.progressRatio),
        textOf(item.canonicalId), textOf(item.linkKey), textOf(item.titleKey)));
    } catch (err) {
      continue;
    }
  }
  return result;
}

function parseHighlights(items: BackupHighlightRaw[] | undefined): BackupHighlight[] {
  const result: BackupHighlight[] = [];
  if (items === undefined || !Array.isArray(items)) {
    return result;
  }
  for (let i = 0; i < items.length; i += 1) {
    try {
      const item: BackupHighlightRaw = items[i];
      const id: string = textOf(item.id);
      const articleId: string = textOf(item.articleId);
      if (!isPresent(id) || !isPresent(articleId)) {
        continue;
      }
      result.push(new BackupHighlight(id, articleId, textOf(item.quote), textOf(item.note),
        textOf(item.color), numberOf(item.createdAt), textOf(item.anchorText),
        numberOf(item.anchorRatio)));
    } catch (err) {
      continue;
    }
  }
  return result;
}

function parseTags(items: BackupTagRaw[] | undefined): BackupTag[] {
  const result: BackupTag[] = [];
  if (items === undefined || !Array.isArray(items)) {
    return result;
  }
  for (let i = 0; i < items.length; i += 1) {
    try {
      const item: BackupTagRaw = items[i];
      const id: string = textOf(item.id);
      const name: string = textOf(item.name);
      if (!isPresent(id) || !isPresent(name)) {
        continue;
      }
      result.push(new BackupTag(id, name, numberOf(item.createdAt)));
    } catch (err) {
      continue;
    }
  }
  return result;
}

function parseArticleTags(items: BackupArticleTagRaw[] | undefined): BackupArticleTag[] {
  const result: BackupArticleTag[] = [];
  if (items === undefined || !Array.isArray(items)) {
    return result;
  }
  for (let i = 0; i < items.length; i += 1) {
    try {
      const item: BackupArticleTagRaw = items[i];
      const articleId: string = textOf(item.articleId);
      const tagId: string = textOf(item.tagId);
      if (!isPresent(articleId) || !isPresent(tagId)) {
        continue;
      }
      result.push(new BackupArticleTag(articleId, tagId));
    } catch (err) {
      continue;
    }
  }
  return result;
}

function parseSmartFolders(items: BackupSmartFolderRaw[] | undefined): BackupSmartFolder[] {
  const result: BackupSmartFolder[] = [];
  if (items === undefined || !Array.isArray(items)) {
    return result;
  }
  for (let i = 0; i < items.length; i += 1) {
    try {
      const item: BackupSmartFolderRaw = items[i];
      const id: string = textOf(item.id);
      const name: string = textOf(item.name);
      if (!isPresent(id) || !isPresent(name)) {
        continue;
      }
      result.push(new BackupSmartFolder(id, name, textOf(item.query),
        nonNegativeInt(item.sortOrder)));
    } catch (err) {
      continue;
    }
  }
  return result;
}

function parseRules(items: BackupRuleRaw[] | undefined): BackupRule[] {
  const result: BackupRule[] = [];
  if (items === undefined || !Array.isArray(items)) {
    return result;
  }
  for (let i = 0; i < items.length; i += 1) {
    try {
      const item: BackupRuleRaw = items[i];
      const id: string = textOf(item.id);
      const name: string = textOf(item.name);
      if (!isPresent(id) || !isPresent(name)) {
        continue;
      }
      result.push(new BackupRule(id, name, booleanOf(item.enabled, true),
        nonNegativeInt(item.priority), stringListOf(item.keywords), stringListOf(item.fields),
        stringListOf(item.feedIds), stringListOf(item.actions), stringListOf(item.tagIds),
        nonNegativeInt(item.matchCount), numberOf(item.lastHitAt)));
    } catch (err) {
      continue;
    }
  }
  return result;
}

function parseTemplates(items: BackupTemplateRaw[] | undefined): BackupTemplate[] {
  const result: BackupTemplate[] = [];
  if (items === undefined || !Array.isArray(items)) {
    return result;
  }
  for (let i = 0; i < items.length; i += 1) {
    try {
      const item: BackupTemplateRaw = items[i];
      const id: string = textOf(item.id);
      const name: string = textOf(item.name);
      if (!isPresent(id) || !isPresent(name)) {
        continue;
      }
      result.push(new BackupTemplate(id, name, textOf(item.content),
        nonNegativeInt(item.sort)));
    } catch (err) {
      continue;
    }
  }
  return result;
}

function parseSettings(raw: Record<string, BackupScalar> | undefined): BackupSettings {
  const values: Record<string, BackupScalar> = {};
  if (raw === undefined) {
    return new BackupSettings(values);
  }
  try {
    const keys: string[] = Object.keys(raw);
    for (let i = 0; i < keys.length; i += 1) {
      const key: string = keys[i];
      if (!isSettingsKeyAllowed(key)) {
        continue;
      }
      const value: BackupScalar = raw[key];
      if (typeof value === 'string' || typeof value === 'boolean') {
        values[key] = value;
      } else if (typeof value === 'number' && Number.isFinite(value)) {
        values[key] = value;
      }
    }
  } catch (err) {
    return new BackupSettings({});
  }
  return new BackupSettings(values);
}

// ---- 公开 API ----

/** 序列化为版本化 JSON；失败返回空串（调用方按失败处理）。 */
export function serialize(doc: BackupDocument): string {
  try {
    return JSON.stringify(doc);
  } catch (err) {
    return '';
  }
}

/**
 * 解析备份文本。版本必须等于 RssConstants.BACKUP_VERSION，否则返回 undefined。
 * 数组缺失 / 非数组 → []；字段类型收敛；单条脏行跳过；未知字段忽略。
 */
export function parse(text: string): BackupDocument | undefined {
  if (text.length === 0 || text.trim().length === 0) {
    return undefined;
  }
  let raw: BackupDocumentRaw;
  try {
    raw = JSON.parse(text) as BackupDocumentRaw;
  } catch (err) {
    return undefined;
  }
  try {
    if (numberOf(raw.version) !== RssConstants.BACKUP_VERSION) {
      return undefined;
    }
    const doc: BackupDocument = new BackupDocument();
    doc.version = RssConstants.BACKUP_VERSION;
    doc.exportedAt = numberOf(raw.exportedAt);
    doc.app = textOr(raw.app, 'HarmonyRss');
    doc.feeds = parseFeeds(raw.feeds);
    doc.articles = parseArticles(raw.articles);
    doc.highlights = parseHighlights(raw.highlights);
    doc.tags = parseTags(raw.tags);
    doc.articleTags = parseArticleTags(raw.articleTags);
    doc.smartFolders = parseSmartFolders(raw.smartFolders);
    doc.rules = parseRules(raw.rules);
    doc.templates = parseTemplates(raw.templates);
    doc.settings = parseSettings(raw.settings);
    return doc;
  } catch (err) {
    // JSON 是合法 JSON 但结构完全不是对象 / 访问字段抛异常：整体拒绝。
    return undefined;
  }
}

export { mergeArticleState, settingsWhitelist, isSettingsKeyAllowed, sanitizeFeed, sanitizeArticle } from './BackupPolicy';
