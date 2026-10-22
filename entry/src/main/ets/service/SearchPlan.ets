/*
 * SearchPlan.ets — 把 SearchQuery 编译成「中文索引 + 候选复核」的查询计划（纯函数、可单测）。
 *
 * 编译规则（见 spec/cjk-search-perf/plan.md R-04）：
 *   单字片段 → 单字 token；
 *   双字片段 → 二元组 token；
 *   ≥3 字片段 → 所有相邻二元组 AND（走索引）+ 子串复核（消除不连续误召回）；
 *   英文片段 → 追加大小写不敏感的 LIKE 复核（候选集已被中文索引收窄）；
 *   纯英文查询不经过这里，继续走主 FTS 索引。
 *
 * 所有 token 都经 escapeFtsToken 转义后进入 MATCH 语法位；复核条件一律绑参数，不拼串。
 */

import { relationalStore } from '@kit.ArkData';
import { CjkQueryPlan, SearchQuery, SearchState } from '../model/Search';
import { hasCjkText, needsPostFilter, queryTokens } from './CjkTokenizer';
import { escapeFtsToken } from './SearchQueryParser';

/** 参与关键词匹配的词：短语优先（与主索引语义一致），否则取普通关键词。 */
export function queryTerms(query: SearchQuery): string[] {
  const terms: string[] = [];
  if (query.phrase.trim().length > 0) {
    terms.push(query.phrase.trim());
    return terms;
  }
  for (let i = 0; i < query.terms.length; i += 1) {
    const term: string = query.terms[i].trim();
    if (term.length > 0) {
      terms.push(term);
    }
  }
  return terms;
}

/** 查询是否需要中文索引路径（含任意 CJK 字符）。 */
export function hasCjk(query: SearchQuery): boolean {
  const terms: string[] = queryTerms(query);
  for (let i = 0; i < terms.length; i += 1) {
    if (hasCjkText(terms[i])) {
      return true;
    }
  }
  return false;
}

/**
 * 空查询保护：既没有关键词，也没有任何过滤条件时不做任何扫描。
 * （只有 `from:` / `is:` / `after:` 这类过滤条件时仍按过滤条件检索，保持既有行为。）
 */
export function isBlankQuery(query: SearchQuery): boolean {
  if (queryTerms(query).length > 0) {
    return false;
  }
  if (query.from.trim().length > 0 || query.after > 0 || query.before > 0) {
    return false;
  }
  return query.state === SearchState.ALL;
}

/** 词里是否含拉丁字母 / 数字（决定复核用 LIKE 还是 instr）。 */
function hasWordChar(text: string): boolean {
  for (let i = 0; i < text.length; i += 1) {
    const code: number = text.charCodeAt(i);
    if (code >= 0x30 && code <= 0x39) {
      return true;
    }
    if ((code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a)) {
      return true;
    }
  }
  return false;
}

/**
 * 编译一次查询：
 *   expression —— 送进 MATCH 的 token 表达式（全角 / 半角特殊字符都已被引号包住）；
 *   postFilters —— 需要在候选集上复核的原词；
 *   used —— expression 非空即表示可以走中文索引。
 */
export function compile(query: SearchQuery): CjkQueryPlan {
  const terms: string[] = queryTerms(query);
  const escaped: string[] = [];
  const postFilters: string[] = [];
  for (let i = 0; i < terms.length; i += 1) {
    const term: string = terms[i];
    const tokens: string[] = queryTokens(term);
    for (let t = 0; t < tokens.length; t += 1) {
      const token: string = escapeFtsToken(tokens[t]);
      if (token.length > 0 && escaped.indexOf(token) < 0) {
        escaped.push(token);
      }
    }
    // 纯英文片段在中文索引里没有 token；≥3 字中文 / 中英混排需要消除近似召回。
    if (tokens.length === 0 || needsPostFilter(term) || (hasCjkText(term) && hasWordChar(term))) {
      postFilters.push(term);
    }
  }
  if (escaped.length === 0) {
    return new CjkQueryPlan('', postFilters, false);
  }
  return new CjkQueryPlan(escaped.join(' AND '), postFilters, true);
}

/**
 * 生成复核条件（`AND (...)` 形式）：
 *   - 含 CJK 的词 → `instr(lower(col), ?) > 0`（双方转小写，中英混排也大小写不敏感）；
 *   - 纯英文词 → `lower(col) LIKE ?`，参数 `%term%`。
 * 参数按 SQL 出现顺序 push 进 args。
 */
export function postFilterSql(plan: CjkQueryPlan, alias: string, args: Array<relationalStore.ValueType>): string {
  let clause: string = '';
  for (let i = 0; i < plan.postFilters.length; i += 1) {
    const term: string = plan.postFilters[i].trim();
    if (term.length === 0) {
      continue;
    }
    const lowered: string = term.toLowerCase();
    if (hasCjkText(term)) {
      clause += ' AND (instr(lower(' + alias + '.title), ?) > 0' +
        ' OR instr(lower(' + alias + '.summary), ?) > 0' +
        ' OR instr(lower(' + alias + '.plain_text), ?) > 0)';
      args.push(lowered);
      args.push(lowered);
      args.push(lowered);
    } else {
      const like: string = '%' + lowered + '%';
      clause += ' AND (lower(' + alias + '.title) LIKE ?' +
        ' OR lower(' + alias + '.summary) LIKE ?' +
        ' OR lower(' + alias + '.plain_text) LIKE ?' +
        ' OR lower(' + alias + '.author) LIKE ?)';
      args.push(like);
      args.push(like);
      args.push(like);
      args.push(like);
    }
  }
  return clause;
}
