/*
 * SearchQueryParser.test.ets — 检索语法解析单测（语法 / 空查询 / 特殊字符 / CJK）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { emptyQuery, escapeFtsToken, parse } from '../../../main/ets/service/SearchQueryParser';
import { SearchQuery, SearchState } from '../../../main/ets/model/Search';

export default function searchQueryParserTest() {
  describe('SearchQueryParser', () => {
    it('parse_plain_terms', 0, () => {
      const query: SearchQuery = parse('harmony rss');
      expect(query.terms.length).assertEqual(2);
      expect(query.terms[0]).assertEqual('harmony');
      expect(query.terms[1]).assertEqual('rss');
      expect(query.state).assertEqual(SearchState.ALL);
    });

    it('parse_from_filter', 0, () => {
      const query: SearchQuery = parse('from:少数派 阅读');
      expect(query.from).assertEqual('少数派');
      expect(query.terms.length).assertEqual(1);
      expect(query.terms[0]).assertEqual('阅读');
    });

    it('parse_from_quoted', 0, () => {
      const query: SearchQuery = parse('from:"The Verge" ai');
      expect(query.from).assertEqual('The Verge');
      expect(query.terms[0]).assertEqual('ai');
    });

    it('parse_state_filter', 0, () => {
      expect(parse('is:unread').state).assertEqual(SearchState.UNREAD);
      expect(parse('is:read').state).assertEqual(SearchState.READ);
      expect(parse('is:starred').state).assertEqual(SearchState.STARRED);
      expect(parse('is:saved').state).assertEqual(SearchState.SAVED);
      // 未知状态退回 all。
      expect(parse('is:whatever').state).assertEqual(SearchState.ALL);
    });

    it('parse_date_range', 0, () => {
      const query: SearchQuery = parse('after:2026-01-01 before:2026-02-01');
      expect(query.after > 0).assertTrue();
      expect(query.before > 0).assertTrue();
      expect(query.before > query.after).assertTrue();
      // 非法日期被忽略，不报错。
      const bad: SearchQuery = parse('after:not-a-date');
      expect(bad.after).assertEqual(0);
    });

    it('parse_phrase', 0, () => {
      const query: SearchQuery = parse('"machine learning" rss');
      expect(query.phrase).assertEqual('machine learning');
      expect(query.terms.length).assertEqual(1);
      expect(query.terms[0]).assertEqual('rss');
    });

    it('empty_query_detection', 0, () => {
      expect(emptyQuery('')).assertTrue();
      expect(emptyQuery('   ')).assertTrue();
      expect(emptyQuery('from:')).assertTrue();
      expect(emptyQuery('is:unread')).assertFalse();
      expect(emptyQuery('from:少数派')).assertFalse();
      expect(emptyQuery('after:2026-01-01')).assertFalse();
      expect(emptyQuery('hello')).assertFalse();
    });

    it('escape_fts_token', 0, () => {
      expect(escapeFtsToken('hello')).assertEqual('"hello"');
      expect(escapeFtsToken('  spaced  ')).assertEqual('"spaced"');
      expect(escapeFtsToken('')).assertEqual('');
      expect(escapeFtsToken('   ')).assertEqual('');
      // 内部双引号按 FTS5 规则翻倍。
      expect(escapeFtsToken('a"b')).assertEqual('"a""b"');
      // 语法字符被引号包住，不会破坏查询。
      expect(escapeFtsToken('C++ AND -x*')).assertEqual('"C++ AND -x*"');
      // 控制字符替换为空格。
      expect(escapeFtsToken('a\u0001b')).assertEqual('"a b"');
    });

    it('cjk_terms', 0, () => {
      const query: SearchQuery = parse('鸿蒙 阅读器');
      expect(query.terms.length).assertEqual(2);
      expect(query.terms[0]).assertEqual('鸿蒙');
      expect(escapeFtsToken('鸿蒙')).assertEqual('"鸿蒙"');
    });

    it('sql_special_chars_safe', 0, () => {
      // 解析阶段不做 SQL 拼接：特殊字符只作为普通关键词保留，转义后整体加引号。
      const query: SearchQuery = parse('100% _test_ \'or 1=1');
      expect(query.terms.length).assertEqual(4);
      const token: string = escapeFtsToken(query.terms[0]);
      expect(token.startsWith('"')).assertTrue();
      expect(token.endsWith('"')).assertTrue();
    });
  });
}
