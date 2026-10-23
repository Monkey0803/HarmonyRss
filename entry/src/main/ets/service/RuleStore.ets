/*
 * RuleStore.ets — 规则的本地存储（Model 层：屏蔽 @ohos.data.relationalStore）。
 *
 * 落库策略（与 v6 表结构一致）：
 *   - keywords / feedIds / tagIds：JSON 字符串数组（数组内容由用户输入决定，读取端逐项容错）；
 *   - fields / actions：逗号串（值域固定为 RuleField / RuleAction 常量）；
 *   - priority：0 起连续，列表按 priority 升序、同优先级按创建时间升序。
 *
 * 任何失败都只记日志并返回空态 / false，绝不抛出：规则是「锦上添花」的功能，
 * 不能因为一条脏数据导致文章入库 / 阅读主链路失败。
 */

import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { Rule, RuleAction, RuleDraft, RuleError, RuleField } from '../model/Rule';
import { ArticleDbConstants, RuleConstants } from '../common/constants/RssConstants';
import { articleStore } from './ArticleStore';
import { validateDraft } from './RuleEngine';

const DOMAIN: number = 0x0000;
const TAG: string = 'RuleStore';

/** 试运行采样用的轻量列（含纯文本正文，正文列可按需截断）。 */
const SAMPLE_COLUMNS: string =
  'id, feed_id, feed_title, title, link, summary, published_at, is_read, is_starred, is_saved,' +
  ' is_hidden, image_url, author, content, plain_text';

/** 生成稳定 id：时间戳 + 随机后缀。 */
function newRuleId(): string {
  return 'rule_' + Date.now() + '_' + Math.floor(Math.random() * 1000000);
}

/** 数组 → JSON 字符串（去空项）。 */
function encodeArray(values: string[]): string {
  const cleaned: string[] = [];
  for (let i = 0; i < values.length; i += 1) {
    const value: string = values[i].trim();
    if (value.length > 0) {
      cleaned.push(value);
    }
  }
  return JSON.stringify(cleaned);
}

/** JSON 字符串 → 数组（脏数据返回空数组）。 */
function decodeArray(text: string): string[] {
  if (text.length === 0) {
    return [];
  }
  try {
    const raw: string[] = JSON.parse(text) as string[];
    const result: string[] = [];
    for (let i = 0; i < raw.length; i += 1) {
      const value: string = raw[i];
      if (typeof value === 'string' && value.trim().length > 0 && result.indexOf(value) < 0) {
        result.push(value);
      }
    }
    return result;
  } catch (err) {
    return [];
  }
}

/** 逗号串 → 只保留合法值（去重、保序）。 */
function decodeCodes(text: string, validator: (value: string) => boolean): string[] {
  const result: string[] = [];
  if (text.length === 0) {
    return result;
  }
  const parts: string[] = text.split(',');
  for (let i = 0; i < parts.length; i += 1) {
    const value: string = parts[i].trim();
    if (value.length > 0 && validator(value) && result.indexOf(value) < 0) {
      result.push(value);
    }
  }
  return result;
}

/** 合法值集合 → 逗号串。 */
function encodeCodes(values: string[], validator: (value: string) => boolean): string {
  const cleaned: string[] = [];
  for (let i = 0; i < values.length; i += 1) {
    const value: string = values[i].trim();
    if (value.length > 0 && validator(value) && cleaned.indexOf(value) < 0) {
      cleaned.push(value);
    }
  }
  return cleaned.join(',');
}

/** 上移 / 下移后的目标下标：越界时原样返回。 */
function movedIndex(index: number, delta: number, length: number): number {
  if (length <= 1) {
    return index;
  }
  const target: number = index + delta;
  if (index < 0 || index >= length || target < 0 || target >= length) {
    return index;
  }
  return target;
}

export class RuleStore {
  /** 全部规则（按 priority 升序；同优先级按创建时间）。库不可用时返回空数组。 */
  async list(): Promise<Rule[]> {
    await articleStore.whenReady();
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    const result: Rule[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id, name, enabled, priority, keywords, fields, feed_ids, actions, tag_ids,' +
        ' match_count, last_hit_at FROM ' + ArticleDbConstants.TABLE_RULES +
        ' ORDER BY priority ASC, created_at ASC');
      try {
        while (rs.goToNextRow()) {
          result.push(this.fromRow(rs));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'list failed: %{public}d', error.code);
    }
    return result;
  }

  /**
   * 新建规则：校验草稿 + 数量上限，通过后追加到末尾（priority = 当前最大值 + 1）。
   * 返回 undefined 表示失败（调用方用 validateDraft 的结果提示具体原因）。
   */
  async create(draft: RuleDraft): Promise<Rule | undefined> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined) {
      return undefined;
    }
    if (validateDraft(draft) !== RuleError.NONE) {
      return undefined;
    }
    const existing: Rule[] = await this.list();
    if (existing.length >= RuleConstants.MAX_RULES) {
      return undefined;
    }
    let nextPriority: number = 0;
    for (let i = 0; i < existing.length; i += 1) {
      nextPriority = Math.max(nextPriority, existing[i].priority + 1);
    }
    const id: string = newRuleId();
    const now: number = Date.now();
    const name: string = draft.name.trim();
    const keywords: string[] = this.cleanKeywords(draft.keywords);
    const fields: string = encodeCodes(draft.fields, (v: string): boolean => RuleField.isValid(v));
    const feedIds: string = encodeArray(draft.feedIds);
    const actions: string = encodeCodes(draft.actions, (v: string): boolean => RuleAction.isValid(v));
    const tagIds: string = encodeArray(draft.tagIds);
    try {
      store.executeSync('INSERT INTO ' + ArticleDbConstants.TABLE_RULES +
        ' (id, name, enabled, priority, keywords, fields, feed_ids, actions, tag_ids,' +
        ' match_count, last_hit_at, created_at, updated_at)' +
        ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [id, name, draft.enabled ? 1 : 0, nextPriority, JSON.stringify(keywords), fields,
          feedIds, actions, tagIds, 0, 0, now, now]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'create failed: %{public}d', error.code);
      return undefined;
    }
    return new Rule(id, name, draft.enabled, nextPriority, keywords,
      decodeCodes(fields, (v: string): boolean => RuleField.isValid(v)),
      decodeArray(feedIds),
      decodeCodes(actions, (v: string): boolean => RuleAction.isValid(v)),
      decodeArray(tagIds), 0, 0);
  }

  /** 编辑规则（保留 priority / 命中统计 / 创建时间）。 */
  async update(id: string, draft: RuleDraft): Promise<boolean> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || id.length === 0) {
      return false;
    }
    if (validateDraft(draft) !== RuleError.NONE) {
      return false;
    }
    try {
      store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_RULES +
        ' SET name = ?, enabled = ?, keywords = ?, fields = ?, feed_ids = ?, actions = ?,' +
        ' tag_ids = ?, updated_at = ? WHERE id = ?',
        [draft.name.trim(), draft.enabled ? 1 : 0, JSON.stringify(this.cleanKeywords(draft.keywords)),
          encodeCodes(draft.fields, (v: string): boolean => RuleField.isValid(v)),
          encodeArray(draft.feedIds),
          encodeCodes(draft.actions, (v: string): boolean => RuleAction.isValid(v)),
          encodeArray(draft.tagIds), Date.now(), id]);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'update failed: %{public}d', error.code);
      return false;
    }
  }

  /** 删除规则（已执行过的文章动作不回滚）。 */
  async remove(id: string): Promise<void> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || id.length === 0) {
      return;
    }
    try {
      store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_RULES + ' WHERE id = ?', [id]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'remove failed: %{public}d', error.code);
    }
  }

  /** 启停。 */
  async setEnabled(id: string, enabled: boolean): Promise<void> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || id.length === 0) {
      return;
    }
    try {
      store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_RULES +
        ' SET enabled = ?, updated_at = ? WHERE id = ?', [enabled ? 1 : 0, Date.now(), id]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'setEnabled failed: %{public}d', error.code);
    }
  }

  /**
   * 上移（delta = -1）/ 下移（delta = 1）：与相邻项交换后重写 0..n-1 的 priority，
   * 保证历史数据里的重复排序位被顺带修正。
   */
  async move(id: string, delta: number): Promise<void> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || id.length === 0 || delta === 0) {
      return;
    }
    const items: Rule[] = await this.list();
    let index: number = -1;
    for (let i = 0; i < items.length; i += 1) {
      if (items[i].id === id) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      return;
    }
    const target: number = movedIndex(index, delta, items.length);
    if (target === index) {
      return;
    }
    const reordered: Rule[] = items.slice();
    const moved: Rule = reordered[index];
    reordered[index] = reordered[target];
    reordered[target] = moved;
    try {
      store.beginTransaction();
      try {
        for (let i = 0; i < reordered.length; i += 1) {
          store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_RULES +
            ' SET priority = ? WHERE id = ?', [i, reordered[i].id]);
        }
        store.commit();
      } catch (inner) {
        store.rollBack();
        throw inner as Error;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'move failed: %{public}d', error.code);
    }
  }

  /**
   * 累加命中统计：match_count += 本批篇数，last_hit_at = 最近一次执行时间。
   * 只处理 count > 0 的规则；同一事务内完成，避免中途失败留下半套统计。
   */
  async recordHits(hits: Map<string, number>, at: number): Promise<void> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || hits.size === 0) {
      return;
    }
    try {
      store.beginTransaction();
      try {
        hits.forEach((count: number, ruleId: string): void => {
          if (count <= 0 || ruleId.length === 0) {
            return;
          }
          store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_RULES +
            ' SET match_count = match_count + ?, last_hit_at = ? WHERE id = ?',
            [count, at, ruleId]);
        });
        store.commit();
      } catch (inner) {
        store.rollBack();
        throw inner as Error;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'recordHits failed: %{public}d', error.code);
    }
  }

  /**
   * 试运行采样：按发布时间倒序取最近 limit 篇（含正文纯文本，供 content 字段匹配）。
   * 只读，不修改任何状态。
   */
  async sampleArticles(limit: number): Promise<Article[]> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    const result: Article[] = [];
    if (store === undefined || limit <= 0) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT ' + SAMPLE_COLUMNS + ' FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' ORDER BY published_at DESC LIMIT ?', [limit]);
      try {
        while (rs.goToNextRow()) {
          result.push(this.sampleRow(rs));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'sampleArticles failed: %{public}d', error.code);
    }
    return result;
  }

  /** 关键词清洗：去空、按小写去重、最多 MAX_RULE_KEYWORDS。 */
  private cleanKeywords(values: string[]): string[] {
    const result: string[] = [];
    const keys: Set<string> = new Set<string>();
    for (let i = 0; i < values.length; i += 1) {
      const value: string = values[i].trim();
      if (value.length === 0) {
        continue;
      }
      const key: string = value.toLowerCase();
      if (keys.has(key)) {
        continue;
      }
      keys.add(key);
      result.push(value);
      if (result.length >= RuleConstants.MAX_RULE_KEYWORDS) {
        break;
      }
    }
    return result;
  }

  private fromRow(rs: relationalStore.ResultSet): Rule {
    return new Rule(
      rs.getString(rs.getColumnIndex('id')),
      rs.getString(rs.getColumnIndex('name')),
      rs.getLong(rs.getColumnIndex('enabled')) === 1,
      rs.getLong(rs.getColumnIndex('priority')),
      decodeArray(rs.getString(rs.getColumnIndex('keywords'))),
      decodeCodes(rs.getString(rs.getColumnIndex('fields')),
        (v: string): boolean => RuleField.isValid(v)),
      decodeArray(rs.getString(rs.getColumnIndex('feed_ids'))),
      decodeCodes(rs.getString(rs.getColumnIndex('actions')),
        (v: string): boolean => RuleAction.isValid(v)),
      decodeArray(rs.getString(rs.getColumnIndex('tag_ids'))),
      rs.getLong(rs.getColumnIndex('match_count')),
      rs.getLong(rs.getColumnIndex('last_hit_at')));
  }

  private sampleRow(rs: relationalStore.ResultSet): Article {
    const content: string = rs.getString(rs.getColumnIndex('content'));
    const plain: string = rs.getString(rs.getColumnIndex('plain_text'));
    const article: Article = new Article(
      rs.getString(rs.getColumnIndex('id')),
      rs.getString(rs.getColumnIndex('feed_id')),
      rs.getString(rs.getColumnIndex('feed_title')),
      rs.getString(rs.getColumnIndex('title')),
      rs.getString(rs.getColumnIndex('link')),
      rs.getString(rs.getColumnIndex('summary')),
      content,
      rs.getLong(rs.getColumnIndex('published_at')));
    article.plainText = plain;
    article.imageUrl = rs.getString(rs.getColumnIndex('image_url'));
    article.author = rs.getString(rs.getColumnIndex('author'));
    article.read = rs.getLong(rs.getColumnIndex('is_read')) === 1;
    article.starred = rs.getLong(rs.getColumnIndex('is_starred')) === 1;
    article.saved = rs.getLong(rs.getColumnIndex('is_saved')) === 1;
    article.hidden = rs.getLong(rs.getColumnIndex('is_hidden')) === 1;
    return article;
  }
}

/** 全局唯一实例。 */
export const ruleStore: RuleStore = new RuleStore();
