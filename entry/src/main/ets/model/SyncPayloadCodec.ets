/* Version-compatible payload serialization and validation. */
import { SyncField, FeedPayload, ArticleStatePayload, WebPagePayload, HighlightPayload, TagPayload, ArticleTagPayload, SmartFolderPayload, RulePayload, TemplatePayload } from './SyncModels';

/** 订阅源载荷编解码（纯函数）。 */
export function encodeFeedPayload(payload: FeedPayload): string {
  return JSON.stringify(payload);
}

export function decodeFeedPayload(text: string): FeedPayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: FeedPayload = JSON.parse(text) as FeedPayload;
    if (typeof payload.url !== 'string' || payload.url.length === 0) {
      return undefined;
    }
    return new FeedPayload(
      payload.url,
      typeof payload.title === 'string' ? payload.title : '',
      typeof payload.siteUrl === 'string' ? payload.siteUrl : '',
      typeof payload.group === 'string' ? payload.group : '',
      payload.enabled !== false);
  } catch (err) {
    return undefined;
  }
}

/**
 * 保存网页载荷编解码（纯函数）。
 * url 是唯一必需字段；其余缺字段退回空串 / 0，脏数据不阻断同步。
 */
export function encodeWebPagePayload(payload: WebPagePayload): string {
  return JSON.stringify(payload);
}

export function decodeWebPagePayload(text: string): WebPagePayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: WebPagePayload = JSON.parse(text) as WebPagePayload;
    if (typeof payload.url !== 'string' || payload.url.length === 0) {
      return undefined;
    }
    const savedAt: number = typeof payload.savedAt === 'number' && Number.isFinite(payload.savedAt)
      ? payload.savedAt : 0;
    return new WebPagePayload(
      payload.url,
      typeof payload.title === 'string' ? payload.title : '',
      typeof payload.source === 'string' ? payload.source : '',
      typeof payload.summary === 'string' ? payload.summary : '',
      savedAt);
  } catch (err) {
    return undefined;
  }
}

/** 文章状态载荷编解码（纯函数；缺字段退回 0 / false，不阻断合并）。 */
export function encodeArticleStatePayload(payload: ArticleStatePayload): string {
  return JSON.stringify(payload);
}

function normalizeField(raw: SyncField | undefined, fallback: string): SyncField {
  if (raw === undefined || raw === null || typeof raw.value !== 'string') {
    return new SyncField(fallback, 0);
  }
  const at: number = typeof raw.at === 'number' && Number.isFinite(raw.at) && raw.at > 0 ? raw.at : 0;
  return new SyncField(raw.value, at);
}

export function decodeArticleStatePayload(text: string): ArticleStatePayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: ArticleStatePayload = JSON.parse(text) as ArticleStatePayload;
    return new ArticleStatePayload(
      normalizeField(payload.read, '0'),
      normalizeField(payload.starred, '0'),
      normalizeField(payload.saved, '0'),
      normalizeField(payload.progress, '0'));
  } catch (err) {
    return undefined;
  }
}

function textOf(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}

function numberOf(value: number | undefined): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

/** 高亮载荷编解码（纯函数；缺 id / articleId 视为无效，不参与应用）。 */
export function encodeHighlightPayload(payload: HighlightPayload): string {
  return JSON.stringify(payload);
}

export function decodeHighlightPayload(text: string): HighlightPayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: HighlightPayload = JSON.parse(text) as HighlightPayload;
    const id: string = textOf(payload.id);
    const articleId: string = textOf(payload.articleId);
    if (id.length === 0 || articleId.length === 0) {
      return undefined;
    }
    return new HighlightPayload(id, articleId, textOf(payload.quote), textOf(payload.note),
      textOf(payload.color), numberOf(payload.createdAt), textOf(payload.anchorText),
      numberOf(payload.anchorRatio));
  } catch (err) {
    return undefined;
  }
}

/** 标签载荷编解码（纯函数）。 */
export function encodeTagPayload(payload: TagPayload): string {
  return JSON.stringify(payload);
}

export function decodeTagPayload(text: string): TagPayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: TagPayload = JSON.parse(text) as TagPayload;
    const name: string = textOf(payload.name);
    if (name.length === 0) {
      return undefined;
    }
    return new TagPayload(name);
  } catch (err) {
    return undefined;
  }
}

/** 文章 ↔ 标签关联载荷编解码（纯函数）。 */
export function encodeArticleTagPayload(payload: ArticleTagPayload): string {
  return JSON.stringify(payload);
}

export function decodeArticleTagPayload(text: string): ArticleTagPayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: ArticleTagPayload = JSON.parse(text) as ArticleTagPayload;
    const articleId: string = textOf(payload.articleId);
    const nameKey: string = textOf(payload.nameKey);
    const name: string = textOf(payload.name);
    if (articleId.length === 0 || nameKey.length === 0 || name.length === 0) {
      return undefined;
    }
    return new ArticleTagPayload(articleId, nameKey, name);
  } catch (err) {
    return undefined;
  }
}

function stringArrayOf(value: string[] | undefined): string[] {
  const result: string[] = [];
  if (value === undefined || value === null) {
    return result;
  }
  for (let i = 0; i < value.length; i += 1) {
    const item: string = value[i];
    if (typeof item === 'string' && item.length > 0) {
      result.push(item);
    }
  }
  return result;
}

/** 智能文件夹载荷编解码。 */
export function encodeSmartFolderPayload(payload: SmartFolderPayload): string {
  return JSON.stringify(payload);
}

export function decodeSmartFolderPayload(text: string): SmartFolderPayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: SmartFolderPayload = JSON.parse(text) as SmartFolderPayload;
    const name: string = textOf(payload.name);
    if (name.length === 0) {
      return undefined;
    }
    return new SmartFolderPayload(name, textOf(payload.query));
  } catch (err) {
    return undefined;
  }
}

/** 规则载荷编解码（数组字段逐项过滤，脏值直接丢弃）。 */
export function encodeRulePayload(payload: RulePayload): string {
  return JSON.stringify(payload);
}

export function decodeRulePayload(text: string): RulePayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: RulePayload = JSON.parse(text) as RulePayload;
    const name: string = textOf(payload.name);
    if (name.length === 0) {
      return undefined;
    }
    return new RulePayload(name, payload.enabled === true,
      stringArrayOf(payload.keywords), stringArrayOf(payload.fields),
      stringArrayOf(payload.actions), stringArrayOf(payload.feedKeys),
      stringArrayOf(payload.tagNames));
  } catch (err) {
    return undefined;
  }
}

/** 分享模板载荷编解码。 */
export function encodeTemplatePayload(payload: TemplatePayload): string {
  return JSON.stringify(payload);
}

export function decodeTemplatePayload(text: string): TemplatePayload | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const payload: TemplatePayload = JSON.parse(text) as TemplatePayload;
    const name: string = textOf(payload.name);
    if (name.length === 0) {
      return undefined;
    }
    return new TemplatePayload(name, textOf(payload.content));
  } catch (err) {
    return undefined;
  }
}
