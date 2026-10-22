/*
 * SearchPlan.test.ets — 查询编译单测（单字 / 双字 / 多字 / 短语 / 中英混合 / 空查询 / 特殊字符）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { relationalStore } from '@kit.ArkData';
import { CjkQueryPlan, SearchQuery } from '../../../main/ets/model/Search';
import { compile, hasCjk, isBlankQuery, postFilterSql, queryTerms } from '../../../main/ets/service/SearchPlan';
import { parse } from '../../../main/ets/service/SearchQueryParser';
import { SearchConstants } from '../../../main/ets/common/constants/RssConstants';

export default function searchPlanTest() {
  describe('SearchPlan', () => {
    it('query_terms', 0, () => {
      expect(queryTerms(parse('harmony rss')).join(',')).assertEqual('harmony,rss');
      // 短语优先（与主索引行为一致）。
      expect(queryTerms(parse('"machine learning" rss')).join(',')).assertEqual('machine learning');
      expect(queryTerms(parse('   ')).length).assertEqual(0);
      // 过滤条件不参与关键词。
      expect(queryTerms(parse('from:少数派 is:unread 阅读')).join(',')).assertEqual('阅读');
    });

    it('has_cjk', 0, () => {
      expect(hasCjk(parse('鸿蒙'))).assertTrue();
      expect(hasCjk(parse('AI 鸿蒙'))).assertTrue();
      expect(hasCjk(parse('"鸿蒙系统"'))).assertTrue();
      expect(hasCjk(parse('harmony rss'))).assertFalse();
      expect(hasCjk(parse('is:unread'))).assertFalse();
    });

    it('compile_single_char', 0, () => {
      const plan: CjkQueryPlan = compile(parse('鸿'));
      expect(plan.used).assertTrue();
      expect(plan.expression).assertEqual('"鸿"');
      expect(plan.postFilters.length).assertEqual(0);
    });

    it('compile_two_chars', 0, () => {
      const plan: CjkQueryPlan = compile(parse('鸿蒙'));
      expect(plan.expression).assertEqual('"鸿蒙"');
      // 双字是精确 token，不需要复核。
      expect(plan.postFilters.length).assertEqual(0);
    });

    it('compile_four_chars', 0, () => {
      const plan: CjkQueryPlan = compile(parse('鸿蒙开发'));
      expect(plan.expression).assertEqual('"鸿蒙" AND "蒙开" AND "开发"');
      expect(plan.postFilters.length).assertEqual(1);
      expect(plan.postFilters[0]).assertEqual('鸿蒙开发');
    });

    it('compile_phrase', 0, () => {
      const plan: CjkQueryPlan = compile(parse('"鸿蒙开发"'));
      expect(plan.expression).assertEqual('"鸿蒙" AND "蒙开" AND "开发"');
      expect(plan.postFilters[0]).assertEqual('鸿蒙开发');
    });

    it('compile_mixed', 0, () => {
      const plan: CjkQueryPlan = compile(parse('AI 鸿蒙'));
      // 英文片段不产索引 token，但会作为复核条件。
      expect(plan.expression).assertEqual('"鸿蒙"');
      expect(plan.postFilters.length).assertEqual(1);
      expect(plan.postFilters[0]).assertEqual('AI');
    });

    it('compile_english_only', 0, () => {
      const plan: CjkQueryPlan = compile(parse('harmony'));
      expect(plan.used).assertFalse();
      expect(plan.expression).assertEqual('');
    });

    it('compile_special_chars', 0, () => {
      // 引号 / 百分号 / 下划线 / 星号不进语法位：只保留 CJK token。
      const plan: CjkQueryPlan = compile(parse('鸿蒙%_*'));
      expect(plan.expression).assertEqual('"鸿" AND "鸿蒙" AND "蒙"');
      expect(plan.expression.indexOf('*')).assertEqual(-1);
      expect(plan.expression.indexOf('%')).assertEqual(-1);
      // 内部双引号按 FTS5 规则翻倍，表达式仍可解析。
      const quoted: CjkQueryPlan = compile(parse('鸿蒙"'));
      expect(quoted.expression).assertEqual('"鸿" AND "鸿蒙" AND "蒙"');
    });

    it('blank_query', 0, () => {
      expect(isBlankQuery(parse(''))).assertTrue();
      expect(isBlankQuery(parse('   '))).assertTrue();
      expect(isBlankQuery(parse('from:'))).assertTrue();
      // 只有过滤条件时仍按过滤条件检索（保持既有行为）。
      expect(isBlankQuery(parse('is:unread'))).assertFalse();
      expect(isBlankQuery(parse('from:少数派'))).assertFalse();
      expect(isBlankQuery(parse('after:2026-01-01'))).assertFalse();
      expect(isBlankQuery(parse('鸿蒙'))).assertFalse();
    });

    it('post_filter_sql_cjk', 0, () => {
      const plan: CjkQueryPlan = compile(parse('鸿蒙开发'));
      const args: Array<relationalStore.ValueType> = [];
      const sql: string = postFilterSql(plan, 'a', args);
      expect(sql.indexOf('instr(lower(a.title), ?) > 0')).assertTrue();
      expect(sql.indexOf('instr(lower(a.plain_text), ?) > 0')).assertTrue();
      // 标题 / 摘要 / 正文三段各一个参数。
      expect(args.length).assertEqual(3);
      expect(args[0] as string).assertEqual('鸿蒙开发');
    });

    it('post_filter_sql_english', 0, () => {
      const plan: CjkQueryPlan = compile(parse('harmony 鸿蒙'));
      const args: Array<relationalStore.ValueType> = [];
      const sql: string = postFilterSql(plan, 'a', args);
      expect(sql.indexOf('lower(a.title) LIKE ?')).assertTrue();
      expect(args.length).assertEqual(4);
      // 大小写不敏感：参数统一转小写。
      expect(args[0] as string).assertEqual('%harmony%');
    });

    it('post_filter_sql_empty', 0, () => {
      const plan: CjkQueryPlan = compile(parse('鸿蒙'));
      const args: Array<relationalStore.ValueType> = [];
      expect(postFilterSql(plan, 'a', args)).assertEqual('');
      expect(args.length).assertEqual(0);
      // 索引路径常量与路由约定一致。
      expect(SearchConstants.PATH_CJK).assertEqual('cjk');
      expect(SearchConstants.PATH_FTS).assertEqual('fts');
      expect(SearchConstants.PATH_LIKE).assertEqual('like');
    });

    it('search_query_fields_untouched', 0, () => {
      const query: SearchQuery = parse('鸿蒙 is:unread after:2026-01-01 from:少数派');
      expect(query.terms[0]).assertEqual('鸿蒙');
      expect(compile(query).used).assertTrue();
    });
  });
}
