/*
 * RuleEngine.test.ets — 规则引擎纯函数单测。
 *
 * 覆盖：
 *   - matches：字段选择（标题 / 摘要 / 正文 / 作者）、多关键词 AND、大小写不敏感、
 *     来源范围（feedIds 为空 = 全部来源 / 指定源）、正文截断上限不越界；
 *   - plan：单规则动作、多规则按 priority 全量执行、read / star / hide / tag 聚合、
 *     重复规则 / 重复标签不重复；
 *   - normalizeKeywords / validateDraft：空、超上限、缺字段 / 动作等边界。
 *
 * 全部用例只依赖纯函数：不打开数据库、不启动 Ability、不触碰单例。
 */

import { describe, it, expect } from '@ohos/hypium';
import { Article } from '../../../main/ets/model/Feed';
import { Rule, RuleAction, RuleDraft, RuleError, RuleField, RulePlan } from '../../../main/ets/model/Rule';
import { matches, normalizeKeywords, plan, validateDraft } from '../../../main/ets/service/RuleEngine';
import { RuleConstants } from '../../../main/ets/common/constants/RssConstants';

/** 构造一条规则（默认启用、优先级 0、来源范围全部、无动作 / 无标签）。 */
function rule(id: string, keywords: string[], fields: string[], actions: string[] = [],
  feedIds: string[] = [], tagIds: string[] = [], priority: number = 0,
  enabled: boolean = true): Rule {
  return new Rule(id, 'r-' + id, enabled, priority, keywords, fields, feedIds, actions, tagIds);
}

/** 构造一篇文章（正文 / 作者按需给出）。 */
function article(id: string, feedId: string, title: string, summary: string = '',
  content: string = '', author: string = ''): Article {
  return new Article(id, feedId, 'feed-' + feedId, title, 'https://example.com/' + id,
    summary, content, 0, '', author);
}

/** 构造草稿（来源范围留空 = 全部来源）。 */
function draft(name: string, keywords: string[], fields: string[], actions: string[],
  tagIds: string[] = []): RuleDraft {
  return new RuleDraft(name, true, keywords, fields, [], actions, tagIds);
}

/** 取标签桶；标签不存在时返回空数组（避免严格模式下到处判 undefined）。 */
function tagBucket(planned: RulePlan, tagId: string): string[] {
  const bucket: string[] | undefined = planned.tagHits.get(tagId);
  return bucket === undefined ? [] : bucket;
}

/** 取单条规则本批命中数；不存在记 0。 */
function ruleHitCount(planned: RulePlan, ruleId: string): number {
  const hits: number | undefined = planned.ruleHits.get(ruleId);
  return hits === undefined ? 0 : hits;
}

const ALL_FIELDS: string[] = RuleField.all();

export default function ruleEngineTest() {
  describe('RuleEngine.matches', () => {
    it('matches_field_scope', 0, () => {
      const item: Article = article('a1', 'f1', 'Hello AI', '摘要里的芯片', '正文提到模型', '张三');
      // 每个字段单独命中。
      expect(matches(rule('r1', ['ai'], [RuleField.TITLE]), item)).assertTrue();
      expect(matches(rule('r2', ['芯片'], [RuleField.SUMMARY]), item)).assertTrue();
      expect(matches(rule('r3', ['模型'], [RuleField.CONTENT]), item)).assertTrue();
      expect(matches(rule('r4', ['张三'], [RuleField.AUTHOR]), item)).assertTrue();
      // 字段范围之外的命中不算：关键词只在摘要，规则只看标题。
      expect(matches(rule('r5', ['芯片'], [RuleField.TITLE]), item)).assertFalse();
      // 字段多选：任一被选中字段命中即可。
      expect(matches(rule('r6', ['芯片'], [RuleField.TITLE, RuleField.SUMMARY]), item)).assertTrue();
      // 脏字段被跳过，不会误命中。
      expect(matches(rule('r7', ['ai'], ['unknownField']), item)).assertFalse();
    });

    it('matches_keywords_and', 0, () => {
      const item: Article = article('a1', 'f1', 'AI 芯片的新进展');
      // 同一规则内多关键词为 AND：全部出现才命中。
      expect(matches(rule('r1', ['ai', '芯片'], [RuleField.TITLE]), item)).assertTrue();
      expect(matches(rule('r2', ['ai', '量子'], [RuleField.TITLE]), item)).assertFalse();
      // AND 不跨字段：标题只有 ai、摘要只有 芯片 → 不命中。
      const split: Article = article('a2', 'f1', 'AI 周报', '芯片观察');
      expect(matches(rule('r3', ['ai', '芯片'], [RuleField.TITLE, RuleField.SUMMARY]), split)).assertFalse();
    });

    it('matches_case_insensitive', 0, () => {
      const item: Article = article('a1', 'f1', 'GPU 与 Ai 加速', '', '', 'Ada');
      expect(matches(rule('r1', ['gpu'], [RuleField.TITLE]), item)).assertTrue();
      expect(matches(rule('r2', ['AI'], [RuleField.TITLE]), item)).assertTrue();
      expect(matches(rule('r3', ['ada'], [RuleField.AUTHOR]), item)).assertTrue();
      // 关键词前后空白被裁掉后仍参与匹配。
      expect(matches(rule('r4', ['  gpu  '], [RuleField.TITLE]), item)).assertTrue();
      // 中文不受大小写转换影响。
      const cjk: Article = article('a2', 'f1', '芯片观察');
      expect(matches(rule('r5', ['芯片'], [RuleField.TITLE]), cjk)).assertTrue();
    });

    it('matches_feed_scope', 0, () => {
      const fromA: Article = article('a1', 'feedA', 'AI 新闻');
      const fromB: Article = article('a2', 'feedB', 'AI 新闻');
      // feedIds 为空 = 全部来源。
      const allFeeds: Rule = rule('r-all', ['ai'], [RuleField.TITLE]);
      expect(allFeeds.feedIds.length).assertEqual(0);
      expect(matches(allFeeds, fromA)).assertTrue();
      expect(matches(allFeeds, fromB)).assertTrue();
      // 指定来源：只匹配该源的文章。
      const onlyA: Rule = rule('r-a', ['ai'], [RuleField.TITLE], [], ['feedA']);
      expect(matches(onlyA, fromA)).assertTrue();
      expect(matches(onlyA, fromB)).assertFalse();
      // 多来源白名单任意命中。
      const multi: Rule = rule('r-multi', ['ai'], [RuleField.TITLE], [], ['feedB', 'feedC']);
      expect(matches(multi, fromB)).assertTrue();
      expect(matches(multi, fromA)).assertFalse();
    });

    it('matches_body_limit', 0, () => {
      const limit: number = RuleConstants.RULE_BODY_LIMIT;
      // 关键词完全落在截断上限内 → 命中。
      const inLimit: string = 'a'.repeat(limit - 100) + 'needle' + 'b'.repeat(500);
      expect(matches(rule('r1', ['needle'], [RuleField.CONTENT]),
        article('a1', 'f1', 'title', '', inLimit))).assertTrue();
      // 关键词整体越过上限 → 不参与匹配。
      const beyond: string = 'a'.repeat(limit) + 'needle';
      expect(matches(rule('r2', ['needle'], [RuleField.CONTENT]),
        article('a2', 'f1', 'title', '', beyond))).assertFalse();
      // 关键词被截断切开 → 不产生假命中。
      const crossed: string = 'a'.repeat(limit - 3) + 'needle';
      expect(matches(rule('r3', ['needle'], [RuleField.CONTENT]),
        article('a3', 'f1', 'title', '', crossed))).assertFalse();
      // 正文为空时回退到已提取的纯文本。
      const noContent: Article = article('a4', 'f1', '只有标题');
      noContent.plainText = '提取后的纯文本里有 needle';
      expect(matches(rule('r4', ['needle'], [RuleField.CONTENT]), noContent)).assertTrue();
    });

    it('matches_rejects_disabled_and_empty_keywords', 0, () => {
      const item: Article = article('a1', 'f1', 'AI 新闻');
      // 停用的规则永不命中。
      expect(matches(rule('r1', ['ai'], [RuleField.TITLE], [], [], [], 0, false), item)).assertFalse();
      // 全空白 / 空关键词视为无关键词（兜脏数据）。
      expect(matches(rule('r2', ['   '], [RuleField.TITLE]), item)).assertFalse();
      expect(matches(rule('r3', [], [RuleField.TITLE]), item)).assertFalse();
    });
  });

  describe('RuleEngine.plan', () => {
    it('plan_single_rule_actions', 0, () => {
      const hit: Article = article('a1', 'f1', 'AI 芯片');
      const miss: Article = article('a2', 'f1', '今日天气');
      const r: Rule = rule('r1', ['ai'], [RuleField.TITLE],
        [RuleAction.READ, RuleAction.TAG], [], ['tag_ai']);
      const planned: RulePlan = plan([r], [hit, miss]);
      expect(planned.readIds.length).assertEqual(1);
      expect(planned.readIds[0]).assertEqual('a1');
      expect(planned.starredIds.length).assertEqual(0);
      expect(planned.hiddenIds.length).assertEqual(0);
      expect(planned.tagIds.length).assertEqual(1);
      expect(planned.tagIds[0]).assertEqual('tag_ai');
      expect(tagBucket(planned, 'tag_ai').length).assertEqual(1);
      expect(tagBucket(planned, 'tag_ai')[0]).assertEqual('a1');
      expect(planned.ruleIds.length).assertEqual(1);
      expect(ruleHitCount(planned, 'r1')).assertEqual(1);
      expect(planned.matched).assertEqual(1);
      expect(planned.isEmpty()).assertFalse();
    });

    it('plan_multi_rules_run_all_by_priority', 0, () => {
      const item: Article = article('a1', 'f1', 'AI 芯片');
      // 传入顺序与优先级相反，验证 plan 内部按 priority 升序执行。
      const starRule: Rule = rule('r-star', ['ai'], [RuleField.TITLE], [RuleAction.STAR], [], [], 1);
      const readRule: Rule = rule('r-read', ['ai'], [RuleField.TITLE], [RuleAction.READ], [], [], 0);
      const planned: RulePlan = plan([starRule, readRule], [item]);
      expect(planned.ruleIds.length).assertEqual(2);
      expect(planned.ruleIds[0]).assertEqual('r-read');
      expect(planned.ruleIds[1]).assertEqual('r-star');
      expect(planned.readIds[0]).assertEqual('a1');
      expect(planned.starredIds[0]).assertEqual('a1');
      // 两条规则都命中同一篇，命中篇数只算一次。
      expect(planned.matched).assertEqual(1);
    });

    it('plan_aggregates_all_actions', 0, () => {
      const item: Article = article('a1', 'f1', 'AI 芯片');
      const r: Rule = rule('r1', ['ai'], [RuleField.TITLE], RuleAction.all(), [],
        ['tag_ai', 'tag_tech']);
      const planned: RulePlan = plan([r], [item]);
      expect(planned.readIds[0]).assertEqual('a1');
      expect(planned.starredIds[0]).assertEqual('a1');
      expect(planned.hiddenIds[0]).assertEqual('a1');
      // 标签登记顺序跟随规则里的 tagIds 顺序。
      expect(planned.tagIds.length).assertEqual(2);
      expect(planned.tagIds[0]).assertEqual('tag_ai');
      expect(planned.tagIds[1]).assertEqual('tag_tech');
      expect(tagBucket(planned, 'tag_tech')[0]).assertEqual('a1');
    });

    it('plan_dedupes_same_article_across_rules', 0, () => {
      const item: Article = article('a1', 'f1', 'AI 芯片');
      // 两条规则都要求已读 + 同一个标签：累加但不重复。
      const r1: Rule = rule('r1', ['ai'], [RuleField.TITLE],
        [RuleAction.READ, RuleAction.TAG], [], ['tag_ai'], 0);
      const r2: Rule = rule('r2', ['芯片'], [RuleField.TITLE],
        [RuleAction.READ, RuleAction.TAG], [], ['tag_ai'], 1);
      const planned: RulePlan = plan([r1, r2], [item]);
      expect(planned.readIds.length).assertEqual(1);
      expect(planned.tagIds.length).assertEqual(1);
      expect(tagBucket(planned, 'tag_ai').length).assertEqual(1);
      expect(planned.matched).assertEqual(1);
      // 统计仍按实际命中分别累加。
      expect(ruleHitCount(planned, 'r1')).assertEqual(1);
      expect(ruleHitCount(planned, 'r2')).assertEqual(1);
    });

    it('plan_dedupes_duplicate_tag_ids', 0, () => {
      const item: Article = article('a1', 'f1', 'AI 芯片');
      // 重复标签 id 只登记一次、也只打一次。
      const r: Rule = rule('r1', ['ai'], [RuleField.TITLE], [RuleAction.TAG], [],
        ['tag_ai', 'tag_ai']);
      const planned: RulePlan = plan([r], [item]);
      expect(planned.tagIds.length).assertEqual(1);
      expect(planned.tagIds[0]).assertEqual('tag_ai');
      expect(tagBucket(planned, 'tag_ai').length).assertEqual(1);
    });

    it('plan_empty_when_nothing_matches', 0, () => {
      const missRule: Rule = rule('r1', ['量子'], [RuleField.TITLE], [RuleAction.READ]);
      const miss: RulePlan = plan([missRule], [article('a1', 'f1', 'AI 芯片')]);
      expect(miss.isEmpty()).assertTrue();
      expect(miss.matched).assertEqual(0);
      expect(miss.ruleIds.length).assertEqual(0);
      expect(miss.ruleHits.size).assertEqual(0);
      // 停用规则即使文本命中也不产生计划。
      const off: Rule = rule('r2', ['ai'], [RuleField.TITLE], [RuleAction.READ], [], [], 0, false);
      const offPlan: RulePlan = plan([off], [article('a2', 'f1', 'AI 芯片')]);
      expect(offPlan.isEmpty()).assertTrue();
      expect(offPlan.matched).assertEqual(0);
      // 空输入不抛异常。
      expect(plan([], []).isEmpty()).assertTrue();
    });
  });

  describe('RuleEngine.normalizeKeywords', () => {
    it('normalize_splits_dedupes_keeps_first_case', 0, () => {
      const list: string[] = normalizeKeywords('AI，ai、芯片;GPU\n\r  AI  ');
      expect(list.length).assertEqual(3);
      expect(list[0]).assertEqual('AI');
      expect(list[1]).assertEqual('芯片');
      expect(list[2]).assertEqual('GPU');
    });

    it('normalize_empty_input', 0, () => {
      expect(normalizeKeywords('').length).assertEqual(0);
      expect(normalizeKeywords('   ').length).assertEqual(0);
      expect(normalizeKeywords('，、;；\n\r').length).assertEqual(0);
    });

    it('normalize_respects_max_keywords', 0, () => {
      const parts: string[] = [];
      const total: number = RuleConstants.MAX_RULE_KEYWORDS + 5;
      for (let i = 0; i < total; i += 1) {
        parts.push('kw' + i);
      }
      const list: string[] = normalizeKeywords(parts.join(','));
      expect(list.length).assertEqual(RuleConstants.MAX_RULE_KEYWORDS);
      expect(list[0]).assertEqual('kw0');
      expect(list[RuleConstants.MAX_RULE_KEYWORDS - 1]).assertEqual('kw9');
    });
  });

  describe('RuleEngine.validateDraft', () => {
    it('validate_name_boundary', 0, () => {
      expect(validateDraft(draft('', ['ai'], ALL_FIELDS, [RuleAction.READ])))
        .assertEqual(RuleError.NAME_EMPTY);
      expect(validateDraft(draft('   ', ['ai'], ALL_FIELDS, [RuleAction.READ])))
        .assertEqual(RuleError.NAME_EMPTY);
      expect(validateDraft(draft('n'.repeat(RuleConstants.MAX_RULE_NAME + 1), ['ai'],
        ALL_FIELDS, [RuleAction.READ]))).assertEqual(RuleError.NAME_TOO_LONG);
      // 恰好达到上限通过。
      expect(validateDraft(draft('n'.repeat(RuleConstants.MAX_RULE_NAME), ['ai'],
        ALL_FIELDS, [RuleAction.READ]))).assertEqual(RuleError.NONE);
    });

    it('validate_keywords_boundary', 0, () => {
      expect(validateDraft(draft('规则', [], ALL_FIELDS, [RuleAction.READ])))
        .assertEqual(RuleError.KEYWORDS_EMPTY);
      expect(validateDraft(draft('规则', ['  '], ALL_FIELDS, [RuleAction.READ])))
        .assertEqual(RuleError.KEYWORDS_EMPTY);
      const over: string[] = [];
      for (let i = 0; i <= RuleConstants.MAX_RULE_KEYWORDS; i += 1) {
        over.push('k' + i);
      }
      expect(validateDraft(draft('规则', over, ALL_FIELDS, [RuleAction.READ])))
        .assertEqual(RuleError.KEYWORDS_TOO_MANY);
      const exact: string[] = over.slice(0, RuleConstants.MAX_RULE_KEYWORDS);
      expect(validateDraft(draft('规则', exact, ALL_FIELDS, [RuleAction.READ])))
        .assertEqual(RuleError.NONE);
    });

    it('validate_fields_actions_tags_boundary', 0, () => {
      // 缺字段（含只有脏字段的情况）。
      expect(validateDraft(draft('规则', ['ai'], [], [RuleAction.READ])))
        .assertEqual(RuleError.FIELDS_EMPTY);
      expect(validateDraft(draft('规则', ['ai'], ['unknownField'], [RuleAction.READ])))
        .assertEqual(RuleError.FIELDS_EMPTY);
      // 缺动作（含只有脏动作的情况）。
      expect(validateDraft(draft('规则', ['ai'], ALL_FIELDS, [])))
        .assertEqual(RuleError.ACTIONS_EMPTY);
      expect(validateDraft(draft('规则', ['ai'], ALL_FIELDS, ['unknownAction'])))
        .assertEqual(RuleError.ACTIONS_EMPTY);
      // 选了「打标签」却没选标签。
      expect(validateDraft(draft('规则', ['ai'], ALL_FIELDS, [RuleAction.TAG])))
        .assertEqual(RuleError.TAGS_EMPTY);
      expect(validateDraft(draft('规则', ['ai'], ALL_FIELDS, [RuleAction.TAG], ['tag_ai'])))
        .assertEqual(RuleError.NONE);
      // 不需要标签的动作不受影响。
      expect(validateDraft(draft('规则', ['ai'], ALL_FIELDS, [RuleAction.HIDE])))
        .assertEqual(RuleError.NONE);
      expect(validateDraft(draft('规则', ['ai'], ALL_FIELDS, RuleAction.all(), ['tag_ai'])))
        .assertEqual(RuleError.NONE);
    });
  });
}
