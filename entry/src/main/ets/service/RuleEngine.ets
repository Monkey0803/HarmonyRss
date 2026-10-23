/*
 * RuleEngine.ets — 规则匹配与动作聚合（纯函数，可单测）。
 *
 * 设计要点：
 *   - 不碰数据库 / 不碰全局单例：输入 Rule + Article，输出命中与否 / 执行计划；
 *   - 同一规则内多个关键词为 **AND**；字段多选（标题 / 摘要 / 正文 / 作者），
 *     任一被选中的字段同时包含全部关键词即视为命中；
 *   - 正文参与匹配前截断到 RuleConstants.RULE_BODY_LIMIT（20,000 字符），避免长文拖慢入库；
 *   - 来源范围：feedIds 为空 = 全部来源；
 *   - 匹配大小写不敏感（统一转小写后比较，中文不受影响）。
 */

import { Article } from '../model/Feed';
import { Rule, RuleAction, RuleDraft, RuleError, RuleField, RulePlan } from '../model/Rule';
import { RuleConstants } from '../common/constants/RssConstants';

/** 关键词分隔符：中英文逗号、顿号、分号、换行 / 回车。 */
const KEYWORD_SEPARATORS: RegExp = /[,，、;；\r\n]+/;

/** 取字段对应的可匹配文本（正文截断；正文为空时退回已提取的纯文本）。 */
function fieldText(article: Article, field: string): string {
  if (field === RuleField.TITLE) {
    return article.title;
  }
  if (field === RuleField.SUMMARY) {
    return article.summary;
  }
  if (field === RuleField.AUTHOR) {
    return article.author;
  }
  if (field === RuleField.CONTENT) {
    const body: string = article.content.length > 0 ? article.content : article.plainText;
    return body.length > RuleConstants.RULE_BODY_LIMIT
      ? body.slice(0, RuleConstants.RULE_BODY_LIMIT)
      : body;
  }
  return '';
}

/** 归一化后的关键词（小写 + 去空白），空的关键词不参与匹配。 */
function normalizedKeywords(rule: Rule): string[] {
  const result: string[] = [];
  for (let i = 0; i < rule.keywords.length; i += 1) {
    const value: string = rule.keywords[i].trim().toLowerCase();
    if (value.length > 0) {
      result.push(value);
    }
  }
  return result;
}

/**
 * 单条规则是否命中单篇文章。
 *
 * 1) 规则停用 → 不命中；
 * 2) 来源范围不匹配 → 不命中；
 * 3) 没有任何关键词 → 不命中（校验层已拒绝，这里兜脏数据）；
 * 4) 任一被选中的字段包含**全部**关键词 → 命中。
 */
export function matches(rule: Rule, article: Article): boolean {
  if (!rule.enabled) {
    return false;
  }
  if (rule.feedIds.length > 0 && rule.feedIds.indexOf(article.feedId) < 0) {
    return false;
  }
  const keywords: string[] = normalizedKeywords(rule);
  if (keywords.length === 0) {
    return false;
  }
  for (let f = 0; f < rule.fields.length; f += 1) {
    const field: string = rule.fields[f];
    if (!RuleField.isValid(field)) {
      continue;
    }
    const text: string = fieldText(article, field).toLowerCase();
    if (text.length === 0) {
      continue;
    }
    let allFound: boolean = true;
    for (let k = 0; k < keywords.length; k += 1) {
      if (text.indexOf(keywords[k]) < 0) {
        allFound = false;
        break;
      }
    }
    if (allFound) {
      return true;
    }
  }
  return false;
}

/** 追加去重（保持首次出现顺序）。 */
function pushUnique(target: string[], seen: Set<string>, id: string): void {
  if (seen.has(id)) {
    return;
  }
  seen.add(id);
  target.push(id);
}

/** 取某个标签当前累计的文章 id（不存在则创建空数组并登记标签顺序）。 */
function tagBucket(tagHits: Map<string, string[]>, tagIds: string[], tagId: string): string[] {
  const existing: string[] | undefined = tagHits.get(tagId);
  if (existing !== undefined) {
    return existing;
  }
  const created: string[] = [];
  tagHits.set(tagId, created);
  tagIds.push(tagId);
  return created;
}

/**
 * 生成执行计划：按 priority 升序（同优先级保持传入顺序）遍历启用规则，
 * 累积已读 / 收藏 / 隐藏文章 id、标签命中、以及每条规则本批命中的篇数。
 *
 * 幂等：同一篇文章被多条规则命中时，id 只出现一次；标签重复同样去重。
 */
export function plan(rules: Rule[], articles: Article[]): RulePlan {
  const sorted: Rule[] = rules.slice();
  sorted.sort((a: Rule, b: Rule): number => a.priority - b.priority);

  const readIds: string[] = [];
  const starredIds: string[] = [];
  const hiddenIds: string[] = [];
  const tagIds: string[] = [];
  const tagHits: Map<string, string[]> = new Map<string, string[]>();
  const ruleIds: string[] = [];
  const ruleHits: Map<string, number> = new Map<string, number>();
  const matchedIds: Set<string> = new Set<string>();
  const readSeen: Set<string> = new Set<string>();
  const starredSeen: Set<string> = new Set<string>();
  const hiddenSeen: Set<string> = new Set<string>();
  const tagSeen: Map<string, Set<string>> = new Map<string, Set<string>>();

  for (let r = 0; r < sorted.length; r += 1) {
    const rule: Rule = sorted[r];
    if (!rule.enabled) {
      continue;
    }
    let hitCount: number = 0;
    const ruleTagIds: string[] = rule.hasAction(RuleAction.TAG) ? rule.tagIds : [];
    for (let a = 0; a < articles.length; a += 1) {
      const article: Article = articles[a];
      if (!matches(rule, article)) {
        continue;
      }
      hitCount += 1;
      matchedIds.add(article.id);
      if (rule.hasAction(RuleAction.READ)) {
        pushUnique(readIds, readSeen, article.id);
      }
      if (rule.hasAction(RuleAction.STAR)) {
        pushUnique(starredIds, starredSeen, article.id);
      }
      if (rule.hasAction(RuleAction.HIDE)) {
        pushUnique(hiddenIds, hiddenSeen, article.id);
      }
      for (let t = 0; t < ruleTagIds.length; t += 1) {
        const tagId: string = ruleTagIds[t];
        const bucket: string[] = tagBucket(tagHits, tagIds, tagId);
        let seen: Set<string> | undefined = tagSeen.get(tagId);
        if (seen === undefined) {
          seen = new Set<string>();
          tagSeen.set(tagId, seen);
        }
        pushUnique(bucket, seen, article.id);
      }
    }
    if (hitCount > 0) {
      ruleIds.push(rule.id);
      ruleHits.set(rule.id, hitCount);
    }
  }

  return new RulePlan(readIds, starredIds, hiddenIds, tagIds, tagHits,
    ruleIds, ruleHits, matchedIds.size);
}

/**
 * 把用户输入的关键词串拆成数组：逗号 / 顿号 / 分号 / 换行分隔，去空、去重（忽略大小写），
 * 最多 RuleConstants.MAX_RULE_KEYWORDS 个（保留用户原始大小写用于展示）。
 */
export function normalizeKeywords(raw: string): string[] {
  const result: string[] = [];
  const keys: Set<string> = new Set<string>();
  const parts: string[] = raw.split(KEYWORD_SEPARATORS);
  for (let i = 0; i < parts.length; i += 1) {
    const value: string = parts[i].trim();
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

/**
 * 校验编辑态草稿，返回 RuleError 常量（NONE 表示通过）。
 *
 * 数量上限（MAX_RULES）由 Store / ViewModel 结合当前条数判断，不在纯函数里做。
 */
export function validateDraft(draft: RuleDraft): string {
  const name: string = draft.name.trim();
  if (name.length === 0) {
    return RuleError.NAME_EMPTY;
  }
  if (name.length > RuleConstants.MAX_RULE_NAME) {
    return RuleError.NAME_TOO_LONG;
  }
  let keywordCount: number = 0;
  for (let i = 0; i < draft.keywords.length; i += 1) {
    if (draft.keywords[i].trim().length > 0) {
      keywordCount += 1;
    }
  }
  if (keywordCount === 0) {
    return RuleError.KEYWORDS_EMPTY;
  }
  if (keywordCount > RuleConstants.MAX_RULE_KEYWORDS) {
    return RuleError.KEYWORDS_TOO_MANY;
  }
  let fieldCount: number = 0;
  for (let i = 0; i < draft.fields.length; i += 1) {
    if (RuleField.isValid(draft.fields[i])) {
      fieldCount += 1;
    }
  }
  if (fieldCount === 0) {
    return RuleError.FIELDS_EMPTY;
  }
  let actionCount: number = 0;
  let wantsTag: boolean = false;
  for (let i = 0; i < draft.actions.length; i += 1) {
    const action: string = draft.actions[i];
    if (!RuleAction.isValid(action)) {
      continue;
    }
    actionCount += 1;
    if (action === RuleAction.TAG) {
      wantsTag = true;
    }
  }
  if (actionCount === 0) {
    return RuleError.ACTIONS_EMPTY;
  }
  if (wantsTag && draft.tagIds.length === 0) {
    return RuleError.TAGS_EMPTY;
  }
  return RuleError.NONE;
}
