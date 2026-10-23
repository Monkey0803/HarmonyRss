/*
 * RuleOrder.test.ets — 规则执行顺序与合并语义单测。
 *
 * 覆盖：
 *   - 优先级升序执行（ruleIds / tagIds 的登记顺序即执行顺序）；
 *   - 同优先级保持输入顺序（RuleStore 以 `ORDER BY priority ASC, created_at ASC` 返回，
 *     Array.sort 稳定 ⇒ 同优先级等价于按 created_at 升序）；
 *   - 后规则的动作是**累加**而不是覆盖（前面的已读 / 收藏不会被后面的规则抹掉）；
 *   - 幂等计划：同一篇文章重复传入不产生重复 id，纯函数两次调用结果一致。
 *
 * 全部用例只依赖 RuleEngine.plan 这一个纯函数，不打开数据库。
 */

import { describe, it, expect } from '@ohos/hypium';
import { Article } from '../../../main/ets/model/Feed';
import { Rule, RuleAction, RulePlan } from '../../../main/ets/model/Rule';
import { plan } from '../../../main/ets/service/RuleEngine';

/** 构造一条按优先级排列的规则（默认启用、来源范围全部）。 */
function ruleAt(id: string, priority: number, actions: string[], tagIds: string[] = [],
  keywords: string[] = ['ai']): Rule {
  return new Rule(id, 'r-' + id, true, priority, keywords, ['title'], [], actions, tagIds);
}

/** 构造一篇文章（标题统一含 ai，便于所有规则命中）。 */
function article(id: string): Article {
  return new Article(id, 'f1', 'feed-f1', 'AI 芯片的新进展', 'https://example.com/' + id,
    '', '', 0, '', '');
}

/** 取标签桶；标签不存在时返回空数组。 */
function tagBucket(planned: RulePlan, tagId: string): string[] {
  const bucket: string[] | undefined = planned.tagHits.get(tagId);
  return bucket === undefined ? [] : bucket;
}

/** 取单条规则本批命中数；不存在记 0。 */
function ruleHitCount(planned: RulePlan, ruleId: string): number {
  const hits: number | undefined = planned.ruleHits.get(ruleId);
  return hits === undefined ? 0 : hits;
}

export default function ruleOrderTest() {
  describe('RuleOrder', () => {
    it('order_priority_ascending', 0, () => {
      const item: Article = article('a1');
      // 传入顺序被打乱，plan 必须按 priority 升序执行。
      const rules: Rule[] = [
        ruleAt('r2', 2, [RuleAction.TAG], ['tag_c']),
        ruleAt('r0', 0, [RuleAction.TAG], ['tag_a']),
        ruleAt('r1', 1, [RuleAction.TAG], ['tag_b'])
      ];
      const planned: RulePlan = plan(rules, [item]);
      expect(planned.ruleIds.length).assertEqual(3);
      expect(planned.ruleIds[0]).assertEqual('r0');
      expect(planned.ruleIds[1]).assertEqual('r1');
      expect(planned.ruleIds[2]).assertEqual('r2');
      // 标签登记顺序同样跟随优先级。
      expect(planned.tagIds.length).assertEqual(3);
      expect(planned.tagIds[0]).assertEqual('tag_a');
      expect(planned.tagIds[1]).assertEqual('tag_b');
      expect(planned.tagIds[2]).assertEqual('tag_c');
    });

    it('order_same_priority_keeps_created_order', 0, () => {
      const item: Article = article('a1');
      // 同优先级：RuleStore 已按 created_at 升序返回，plan 需保持该顺序（稳定排序）。
      const older: Rule = ruleAt('r-older', 0, [RuleAction.TAG], ['tag_older']);
      const newer: Rule = ruleAt('r-newer', 0, [RuleAction.TAG], ['tag_newer']);
      const planned: RulePlan = plan([older, newer], [item]);
      expect(planned.ruleIds[0]).assertEqual('r-older');
      expect(planned.ruleIds[1]).assertEqual('r-newer');
      expect(planned.tagIds[0]).assertEqual('tag_older');
      expect(planned.tagIds[1]).assertEqual('tag_newer');
      // 反过来传（created_at 更晚的先给）时保持传入顺序，证明只按 priority 排序。
      const reversed: RulePlan = plan([newer, older], [item]);
      expect(reversed.ruleIds[0]).assertEqual('r-newer');
      expect(reversed.ruleIds[1]).assertEqual('r-older');
    });

    it('order_later_rule_accumulates_actions', 0, () => {
      const item: Article = article('a1');
      const readRule: Rule = ruleAt('r-read', 0, [RuleAction.READ]);
      const starTagRule: Rule = ruleAt('r-star-tag', 1, [RuleAction.STAR, RuleAction.TAG], ['tag_ai']);
      const hideRule: Rule = ruleAt('r-hide', 2, [RuleAction.HIDE]);
      const planned: RulePlan = plan([readRule, starTagRule, hideRule], [item]);
      // 后规则的动作是在前面基础上累加，不会覆盖前一条规则的结果。
      expect(planned.readIds.length).assertEqual(1);
      expect(planned.readIds[0]).assertEqual('a1');
      expect(planned.starredIds.length).assertEqual(1);
      expect(planned.starredIds[0]).assertEqual('a1');
      expect(planned.hiddenIds.length).assertEqual(1);
      expect(planned.hiddenIds[0]).assertEqual('a1');
      expect(tagBucket(planned, 'tag_ai').length).assertEqual(1);
      expect(tagBucket(planned, 'tag_ai')[0]).assertEqual('a1');
      // 每条规则各自统计命中数，文章总命中篇数只算一次。
      expect(ruleHitCount(planned, 'r-read')).assertEqual(1);
      expect(ruleHitCount(planned, 'r-star-tag')).assertEqual(1);
      expect(ruleHitCount(planned, 'r-hide')).assertEqual(1);
      expect(planned.matched).assertEqual(1);
      expect(planned.isEmpty()).assertFalse();
    });

    it('order_idempotent_plan', 0, () => {
      const item: Article = article('a1');
      const r: Rule = ruleAt('r1', 0, RuleAction.all(), ['tag_ai']);
      const once: RulePlan = plan([r], [item]);
      // 同一篇重复传入（例如本地抓取与远端同步拿到同一 id）：动作 id 不重复。
      const twice: RulePlan = plan([r], [item, item]);
      expect(twice.readIds.length).assertEqual(1);
      expect(twice.starredIds.length).assertEqual(1);
      expect(twice.hiddenIds.length).assertEqual(1);
      expect(tagBucket(twice, 'tag_ai').length).assertEqual(1);
      expect(twice.matched).assertEqual(1);
      // 纯函数：同一输入重复执行，计划规模不变（不会累积副作用）。
      expect(once.readIds.length).assertEqual(twice.readIds.length);
      expect(once.starredIds.length).assertEqual(twice.starredIds.length);
      expect(once.hiddenIds.length).assertEqual(twice.hiddenIds.length);
      expect(once.tagIds.length).assertEqual(twice.tagIds.length);
      expect(once.ruleIds.length).assertEqual(twice.ruleIds.length);
    });

    it('order_result_set_independent_of_input_order', 0, () => {
      const item: Article = article('a1');
      // 优先级不同 ⇒ 无论输入顺序如何，执行顺序与结果集合一致。
      const rules: Rule[] = [
        ruleAt('r0', 0, [RuleAction.TAG], ['tag_a']),
        ruleAt('r1', 1, [RuleAction.READ])
      ];
      const forward: RulePlan = plan(rules, [item]);
      const backward: RulePlan = plan([rules[1], rules[0]], [item]);
      expect(forward.ruleIds[0]).assertEqual('r0');
      expect(backward.ruleIds[0]).assertEqual('r0');
      expect(forward.tagIds[0]).assertEqual(backward.tagIds[0]);
      expect(forward.readIds.length).assertEqual(backward.readIds.length);
      expect(forward.matched).assertEqual(backward.matched);
    });
  });
}
