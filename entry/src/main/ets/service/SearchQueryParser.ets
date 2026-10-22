/*
 * SearchQueryParser.ets — 检索语法的纯函数解析（无副作用、可单测）。
 *
 * 支持：
 *   from:少数派            来源过滤（可用引号包住带空格的来源名）
 *   is:unread|read|starred|saved
 *   after:YYYY-MM-DD       发布时间 >= 当天 00:00
 *   before:YYYY-MM-DD      发布时间 <  次日 00:00
 *   "完整短语"             短语整体匹配
 * 其余按空白切分为普通关键词（AND 关系）。
 */

import { SearchQuery, SearchState, normalizeSearchState } from '../model/Search';

/** 日期字符串解析：YYYY-MM-DD / YYYY/MM/DD；返回当天 00:00（endOfDay 时返回次日 00:00）。 */
function parseDate(value: string, endOfDay: boolean): number {
  const text: string = value.trim();
  const normalized: string = text.replace(/\//g, '-');
  const match: RegExpMatchArray | null = normalized.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
  if (match === null) {
    return 0;
  }
  const year: number = Number(match[1]);
  const month: number = Number(match[2]);
  const day: number = Number(match[3]);
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)) {
    return 0;
  }
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    return 0;
  }
  const date: Date = new Date(year, month - 1, day, 0, 0, 0, 0);
  if (endOfDay) {
    date.setDate(date.getDate() + 1);
  }
  return date.getTime();
}

/** 按空白切分，但双引号内的空白不切（保留短语）。 */
function tokenize(raw: string): string[] {
  const tokens: string[] = [];
  let current: string = '';
  let inQuote: boolean = false;
  for (let i = 0; i < raw.length; i += 1) {
    const ch: string = raw.charAt(i);
    if (ch === '"') {
      inQuote = !inQuote;
      current += ch;
      continue;
    }
    if (!inQuote && (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r')) {
      if (current.length > 0) {
        tokens.push(current);
        current = '';
      }
      continue;
    }
    current += ch;
  }
  if (current.length > 0) {
    tokens.push(current);
  }
  return tokens;
}

/** 去掉首尾成对引号。 */
function unquote(value: string): string {
  let text: string = value.trim();
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    text = text.substring(1, text.length - 1);
  }
  return text.trim();
}

/** 解析一次原始输入。空 / 纯语法标记也返回结构完整的 SearchQuery（空页由 emptyQuery 判定）。 */
export function parse(raw: string): SearchQuery {
  const query: SearchQuery = new SearchQuery(raw);
  const tokens: string[] = tokenize(raw);
  const phrases: string[] = [];
  for (let i = 0; i < tokens.length; i += 1) {
    const token: string = tokens[i];
    if (token.startsWith('"')) {
      const phrase: string = unquote(token);
      if (phrase.length > 0) {
        phrases.push(phrase);
      }
      continue;
    }
    const lower: string = token.toLowerCase();
    if (lower.startsWith('from:')) {
      const value: string = unquote(token.substring(5));
      if (value.length > 0) {
        // 多个来源以逗号分隔时只取第一个（SQL 侧按单值过滤，避免拼接注入面）。
        query.from = value.split(',')[0].trim();
      }
      continue;
    }
    if (lower.startsWith('is:')) {
      const value: string = token.substring(3).trim().toLowerCase();
      if (value.length > 0) {
        query.state = normalizeSearchState(value);
      }
      continue;
    }
    if (lower.startsWith('after:')) {
      const ts: number = parseDate(token.substring(6), false);
      if (ts > 0) {
        query.after = ts;
      }
      continue;
    }
    if (lower.startsWith('before:')) {
      const ts: number = parseDate(token.substring(7), true);
      if (ts > 0) {
        query.before = ts;
      }
      continue;
    }
    if (token.length > 0) {
      query.terms.push(token);
    }
  }
  if (phrases.length > 0) {
    query.phrase = phrases.join(' ');
    // 有短语时普通词仍然作为附加条件保留（AND）。
  }
  return query;
}

/**
 * 是否「空查询」：只有过滤条件（如 is:unread / after:…）不算空；
 * 既没有关键词、也没有任何过滤条件（例如只输入了 `from:`）才算空。
 */
export function emptyQuery(raw: string): boolean {
  const query: SearchQuery = parse(raw);
  if (query.terms.length > 0 || query.phrase.length > 0) {
    return false;
  }
  if (query.from.length > 0 || query.after > 0 || query.before > 0) {
    return false;
  }
  return query.state === SearchState.ALL;
}

/**
 * FTS5 token 转义：整词加引号（避免 `*` `-` `OR` 等被当作语法），
 * 内部双引号按 FTS5 规则用两个双引号转义，控制字符替换为空格。
 */
export function escapeFtsToken(term: string): string {
  const cleaned: string = term.replace(/"/g, '""').replace(/[\u0000-\u001f]/g, ' ').trim();
  if (cleaned.length === 0) {
    return '';
  }
  return '"' + cleaned + '"';
}
