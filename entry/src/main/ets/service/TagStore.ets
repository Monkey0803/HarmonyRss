/*
 * TagStore.ets — 标签的本地存储（Model 层：屏蔽 SQL）。
 *
 * 复用 ArticleStore 打开的同一个 RdbStore（同进程不重复打开同名库）。
 * 设计要点：
 *   1. 名称归一：trim + 连续空白折叠为单空格 + 截断到 32 字符；name_key = 归一后小写，
 *      作为 UNIQUE 去重键（大小写不敏感），重命名只改 name / name_key，关联表不动。
 *   2. 多标签筛选是 AND 语义：JOIN article_tags 后 GROUP BY 文章，HAVING COUNT(DISTINCT tag_id) = N。
 *   3. 计数与筛选都 JOIN articles，所以「已删除 / 已在回收站」的文章不会计入 ——
 *      但 article_tags 行在「移入回收站」时保留，7 天内恢复能连标签一起回来。
 *   4. 文章列表只取轻量列（不含正文），避免标签页把全文读进内存。
 */

import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { TagWithCount } from '../model/Tag';
import { ArticleDbConstants, ReaderState, TagConstants } from '../common/constants/RssConstants';
import { articleStore } from './ArticleStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'TagStore';

/** 轻量列表列（与 ArticleStore.loadForList 完全一致：不含正文 / HTML / 纯文本）。 */
const LIST_COLUMNS: string =
  'a.id, a.feed_id, a.feed_title, a.title, a.link, a.summary, a.published_at, a.is_read,' +
  ' a.is_starred, a.is_saved, a.image_url, a.author, a.progress, a.progress_ratio,' +
  ' (CASE WHEN a.reader_html <> \'\' THEN 1 ELSE 0 END) AS has_reader';

/**
 * 名称归一：去掉首尾空白、把连续空白折叠成单个空格，并按上限截断。
 * 纯函数（可单测）：不做大小写变换 —— 展示名保留用户输入的大小写。
 */
export function normalizeTagName(raw: string): string {
  const collapsed: string = raw.replace(/\s+/g, ' ').trim();
  return collapsed.length > TagConstants.TAG_NAME_MAX
    ? collapsed.substring(0, TagConstants.TAG_NAME_MAX).trim()
    : collapsed;
}

/** 去重键：归一后转小写（大小写不敏感去重）。纯函数（可单测）。 */
export function tagNameKey(raw: string): string {
  return normalizeTagName(raw).toLowerCase();
}

/** 名称是否可用（归一后非空且不超过上限）。纯函数（可单测）。 */
export function isValidTagName(raw: string): boolean {
  const normalized: string = normalizeTagName(raw);
  return normalized.length > 0 && normalized.length <= TagConstants.TAG_NAME_MAX;
}

/** 数量是否仍在软上限内。纯函数（可单测）。 */
export function canCreateTag(existingCount: number): boolean {
  return existingCount < TagConstants.MAX_TAGS;
}

/**
 * 多标签 AND 查询的 SQL 片段（纯函数，便于单测校验语义）。
 * 返回 WHERE / GROUP BY / HAVING 三段，调用方自行拼接 SELECT 与 ORDER BY。
 */
export function multiTagAndClause(tagCount: number): string {
  return ' WHERE at.tag_id IN (' + placeholders(tagCount) + ')' +
    ' GROUP BY a.id HAVING COUNT(DISTINCT at.tag_id) = ' + Math.max(0, Math.round(tagCount));
}

/**
 * 多标签 AND + 跨源去重：只取主条（重复项在组内，不进标签文章列表 / 计数）。
 * 与 multiTagAndClause 语义一致，只是多一个 canonical_id 条件；单独保留旧函数不影响既有单测。
 */
function multiTagAndClauseMainOnly(tagCount: number): string {
  return ' WHERE at.tag_id IN (' + placeholders(tagCount) + ') AND a.canonical_id = \'\'' +
    ' GROUP BY a.id HAVING COUNT(DISTINCT at.tag_id) = ' + Math.max(0, Math.round(tagCount));
}

/** 生成 n 个占位符（IN (?,?,…) 用）。 */
function placeholders(count: number): string {
  const parts: string[] = [];
  for (let i = 0; i < count; i += 1) {
    parts.push('?');
  }
  return parts.join(',');
}

/** 生成稳定 id：时间戳 + 随机后缀（同一毫秒内多次创建也不会撞）。 */
function newId(prefix: string): string {
  return prefix + Date.now() + '_' + Math.floor(Math.random() * 1000000);
}

export class TagStore {
  /** 标签列表 + 关联文章数，按名称排序（大小写不敏感）。库不可用时返回空数组。 */
  async listTags(): Promise<TagWithCount[]> {
    // 冷启动时订阅页可能早于 open() 完成就读取计数：先等库就绪，避免首屏显示 0。
    await articleStore.whenReady();
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    const result: TagWithCount[] = [];
    if (store === undefined) {
      return result;
    }
    const sql: string = 'SELECT t.id, t.name, t.created_at, COUNT(a.id) AS c FROM ' +
      ArticleDbConstants.TABLE_TAGS + ' t' +
      ' LEFT JOIN ' + ArticleDbConstants.TABLE_ARTICLE_TAGS + ' at ON at.tag_id = t.id' +
      ' LEFT JOIN ' + ArticleDbConstants.TABLE_ARTICLES + ' a ON a.id = at.article_id' +
      ' GROUP BY t.id ORDER BY t.name COLLATE NOCASE ASC';
    try {
      const rs: relationalStore.ResultSet = await store.querySql(sql);
      try {
        while (rs.goToNextRow()) {
          result.push(new TagWithCount(
            rs.getString(rs.getColumnIndex('id')),
            rs.getString(rs.getColumnIndex('name')),
            rs.getLong(rs.getColumnIndex('c')),
            rs.getLong(rs.getColumnIndex('created_at'))));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'listTags failed: %{public}d', error.code);
    }
    return result;
  }

  /**
   * 新建标签：名称归一后去重（已存在则返回已有标签），超过软上限返回 undefined。
   * 归一后为空也返回 undefined（视图据此提示）。
   */
  async create(name: string): Promise<TagWithCount | undefined> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined) {
      return undefined;
    }
    const display: string = normalizeTagName(name);
    if (display.length === 0) {
      return undefined;
    }
    const key: string = display.toLowerCase();
    const existing: TagWithCount | undefined = await this.findByKey(key);
    if (existing !== undefined) {
      return existing;
    }
    if (!canCreateTag(await this.countTags())) {
      return undefined;
    }
    const id: string = newId('tag_');
    const now: number = Date.now();
    try {
      store.executeSync('INSERT OR IGNORE INTO ' + ArticleDbConstants.TABLE_TAGS +
        ' (id, name, name_key, created_at) VALUES (?, ?, ?, ?)', [id, display, key, now]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'create failed: %{public}d', error.code);
      return undefined;
    }
    // 并发 / 重试路径：INSERT OR IGNORE 被唯一键挡下时，回查已有标签返回。
    const saved: TagWithCount | undefined = await this.findByKey(key);
    return saved;
  }

  /** 重命名：归一后为空或与其它标签重名时返回 false（失败不产生悬挂关联）。 */
  async rename(id: string, name: string): Promise<boolean> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || id.length === 0) {
      return false;
    }
    const display: string = normalizeTagName(name);
    if (display.length === 0) {
      return false;
    }
    const key: string = display.toLowerCase();
    const owner: TagWithCount | undefined = await this.findByKey(key);
    if (owner !== undefined && owner.id !== id) {
      return false;
    }
    try {
      store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_TAGS +
        ' SET name = ?, name_key = ? WHERE id = ?', [display, key, id]);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'rename failed: %{public}d', error.code);
      return false;
    }
  }

  /** 删除标签（连同关联行）；文章本身不受影响。 */
  async remove(id: string): Promise<void> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || id.length === 0) {
      return;
    }
    try {
      store.beginTransaction();
      try {
        store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLE_TAGS +
          ' WHERE tag_id = ?', [id]);
        store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_TAGS + ' WHERE id = ?', [id]);
        store.commit();
      } catch (inner) {
        store.rollBack();
        throw inner as Error;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'remove failed: %{public}d', error.code);
    }
  }

  /** 批量打标（事务 + INSERT OR IGNORE）：返回新增的关联条数，重复添加不产生重复行。 */
  async addToArticles(tagId: string, ids: string[]): Promise<number> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || tagId.length === 0 || ids.length === 0) {
      return 0;
    }
    let added: number = 0;
    try {
      store.beginTransaction();
      try {
        for (let i = 0; i < ids.length; i += 1) {
          store.executeSync('INSERT OR IGNORE INTO ' + ArticleDbConstants.TABLE_ARTICLE_TAGS +
            ' (article_id, tag_id) VALUES (?, ?)', [ids[i], tagId]);
          if (this.lastChanges() > 0) {
            added += 1;
          }
        }
        store.commit();
      } catch (inner) {
        store.rollBack();
        throw inner as Error;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'addToArticles failed: %{public}d', error.code);
      return 0;
    }
    return added;
  }

  /** 从单篇文章移除一个标签。 */
  async removeFromArticle(tagId: string, articleId: string): Promise<void> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || tagId.length === 0 || articleId.length === 0) {
      return;
    }
    try {
      store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLE_TAGS +
        ' WHERE tag_id = ? AND article_id = ?', [tagId, articleId]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'removeFromArticle failed: %{public}d', error.code);
    }
  }

  /** 一篇文章的标签（含计数，供详情页 chips 展示）。 */
  async tagsOfArticle(articleId: string): Promise<TagWithCount[]> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    const result: TagWithCount[] = [];
    if (store === undefined || articleId.length === 0) {
      return result;
    }
    const sql: string = 'SELECT t.id, t.name, t.created_at, COUNT(a.id) AS c FROM ' +
      ArticleDbConstants.TABLE_TAGS + ' t' +
      ' JOIN ' + ArticleDbConstants.TABLE_ARTICLE_TAGS + ' at ON at.tag_id = t.id' +
      ' LEFT JOIN ' + ArticleDbConstants.TABLE_ARTICLES + ' a ON a.id = at.article_id' +
      ' WHERE at.article_id = ? GROUP BY t.id ORDER BY t.name COLLATE NOCASE ASC';
    try {
      const rs: relationalStore.ResultSet = await store.querySql(sql, [articleId]);
      try {
        while (rs.goToNextRow()) {
          result.push(new TagWithCount(
            rs.getString(rs.getColumnIndex('id')),
            rs.getString(rs.getColumnIndex('name')),
            rs.getLong(rs.getColumnIndex('c')),
            rs.getLong(rs.getColumnIndex('created_at'))));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'tagsOfArticle failed: %{public}d', error.code);
    }
    return result;
  }

  /**
   * 多标签 AND 查询：只显示**同时具备**全部标签的文章，按发布时间倒序分页。
   * 只取轻量列 —— 打开文章时再由 FeedViewModel / ArticleStore 补正文。
   */
  async articlesByTags(tagIds: string[], offset: number, limit: number): Promise<Article[]> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    const result: Article[] = [];
    if (store === undefined || tagIds.length === 0 || limit <= 0) {
      return result;
    }
    const args: Array<relationalStore.ValueType> = [];
    for (let i = 0; i < tagIds.length; i += 1) {
      args.push(tagIds[i]);
    }
    args.push(Math.max(0, Math.round(limit)));
    args.push(Math.max(0, Math.round(offset)));
    const sql: string = 'SELECT ' + LIST_COLUMNS + ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a' +
      ' JOIN ' + ArticleDbConstants.TABLE_ARTICLE_TAGS + ' at ON at.article_id = a.id' +
      multiTagAndClauseMainOnly(tagIds.length) +
      ' ORDER BY a.published_at DESC LIMIT ? OFFSET ?';
    try {
      const rs: relationalStore.ResultSet = await store.querySql(sql, args);
      try {
        while (rs.goToNextRow()) {
          result.push(this.articleFromRow(rs));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'articlesByTags failed: %{public}d', error.code);
    }
    return result;
  }

  /** 多标签 AND 命中的文章总数（分页 / 空态用）。 */
  async countByTags(tagIds: string[]): Promise<number> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || tagIds.length === 0) {
      return 0;
    }
    const args: Array<relationalStore.ValueType> = [];
    for (let i = 0; i < tagIds.length; i += 1) {
      args.push(tagIds[i]);
    }
    const sql: string = 'SELECT COUNT(*) AS c FROM (SELECT a.id FROM ' +
      ArticleDbConstants.TABLE_ARTICLES + ' a JOIN ' + ArticleDbConstants.TABLE_ARTICLE_TAGS +
      ' at ON at.article_id = a.id' + multiTagAndClauseMainOnly(tagIds.length) + ')';
    try {
      const rs: relationalStore.ResultSet = await store.querySql(sql, args);
      try {
        if (rs.goToNextRow()) {
          return rs.getLong(rs.getColumnIndex('c'));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'countByTags failed: %{public}d', error.code);
    }
    return 0;
  }

  /** 标签总数（入口计数 / 软上限判断）。 */
  async countTags(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_TAGS);
      try {
        if (rs.goToNextRow()) {
          return rs.getLong(rs.getColumnIndex('c'));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'countTags failed: %{public}d', error.code);
    }
    return 0;
  }

  /** 按 name_key 查已有标签（去重 / 重命名冲突检查）。 */
  private async findByKey(key: string): Promise<TagWithCount | undefined> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || key.length === 0) {
      return undefined;
    }
    const sql: string = 'SELECT t.id, t.name, t.created_at, COUNT(a.id) AS c FROM ' +
      ArticleDbConstants.TABLE_TAGS + ' t' +
      ' LEFT JOIN ' + ArticleDbConstants.TABLE_ARTICLE_TAGS + ' at ON at.tag_id = t.id' +
      ' LEFT JOIN ' + ArticleDbConstants.TABLE_ARTICLES + ' a ON a.id = at.article_id' +
      ' WHERE t.name_key = ? GROUP BY t.id';
    try {
      const rs: relationalStore.ResultSet = await store.querySql(sql, [key]);
      try {
        if (rs.goToNextRow()) {
          return new TagWithCount(
            rs.getString(rs.getColumnIndex('id')),
            rs.getString(rs.getColumnIndex('name')),
            rs.getLong(rs.getColumnIndex('c')),
            rs.getLong(rs.getColumnIndex('created_at')));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'findByKey failed: %{public}d', error.code);
    }
    return undefined;
  }

  /** 轻量行 → Article（与 ArticleStore.loadForList 的字段映射保持一致）。 */
  private articleFromRow(rs: relationalStore.ResultSet): Article {
    const article: Article = new Article(
      rs.getString(rs.getColumnIndex('id')),
      rs.getString(rs.getColumnIndex('feed_id')),
      rs.getString(rs.getColumnIndex('feed_title')),
      rs.getString(rs.getColumnIndex('title')),
      rs.getString(rs.getColumnIndex('link')),
      rs.getString(rs.getColumnIndex('summary')),
      '',
      rs.getLong(rs.getColumnIndex('published_at')));
    article.imageUrl = rs.getString(rs.getColumnIndex('image_url'));
    article.author = rs.getString(rs.getColumnIndex('author'));
    article.read = rs.getLong(rs.getColumnIndex('is_read')) === 1;
    article.starred = rs.getLong(rs.getColumnIndex('is_starred')) === 1;
    article.saved = rs.getLong(rs.getColumnIndex('is_saved')) === 1;
    article.progress = rs.getDouble(rs.getColumnIndex('progress'));
    article.progressRatio = rs.getDouble(rs.getColumnIndex('progress_ratio'));
    article.readerState = rs.getLong(rs.getColumnIndex('has_reader')) === 1
      ? ReaderState.READY
      : ReaderState.NONE;
    return article;
  }

  /** 最近一条语句影响的行数（INSERT OR IGNORE 是否真的插入）。 */
  private lastChanges(): number {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync('SELECT changes() AS c');
      try {
        if (rs.goToNextRow()) {
          return rs.getLong(rs.getColumnIndex('c'));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      return 0;
    }
    return 0;
  }
}

/** 全局唯一实例。 */
export const tagStore: TagStore = new TagStore();
