/*
 * DedupePlan.test.ets — 跨源去重的「匹配决策」纯逻辑单测。
 *
 * 覆盖：
 *   - findMatches：URL 命中、标题 + 时间窗命中、同源不合并、重复项解析到根主条、
 *     同一 incoming 只匹配一次（URL 优先）、批内第二篇并入第一篇；
 *   - resolveRoot：沿 canonicalId 解析到根（含链式）；
 *   - pickPromotion：最早发布者优先、发布时间缺失视为最晚、空列表；
 *   - 幂等：同一输入重复调用结果完全一致。
 *
 * 全部用例只调用 DedupeService 的 static 纯决策方法，不打开数据库。
 */

import { describe, it, expect } from '@ohos/hypium';
import { DedupeCandidate } from '../../../main/ets/model/Dedupe';
import { DedupeService } from '../../../main/ets/service/DedupeService';

/** 24 小时（毫秒）。 */
const DAY_MS: number = 24 * 60 * 60 * 1000;
/** 一小时（毫秒）。 */
const HOUR_MS: number = 60 * 60 * 1000;
/** 基准发布时间。 */
const T0: number = 1700000000000;

/** 构造候选：默认有 canonicalId、无键、无时间。 */
function at(id: string, feedId: string, canonicalId: string = '', linkKey: string = 'L-' + id,
  titleKey: string = 'T-' + id, publishedAt: number = T0): DedupeCandidate {
  return new DedupeCandidate(id, feedId, canonicalId, linkKey, titleKey, publishedAt);
}

/** 取匹配结果（不存在返回空串，便于断言）。 */
function rootOf(matches: Map<string, string>, id: string): string {
  const hit: string | undefined = matches.get(id);
  return hit === undefined ? '' : hit;
}

export default function dedupePlanTest() {
  describe('DedupePlan', () => {
    // ---------- findMatches ----------

    it('plan_match_by_url', 0, () => {
      const existing: DedupeCandidate[] = [at('a1', 'f1', '', 'https://example.com/p', 'title-a')];
      const incoming: DedupeCandidate[] = [
        at('b1', 'f2', '', 'https://example.com/p', '完全不同的标题'),
        at('b2', 'f3', '', 'https://example.com/other', 'title-b2')
      ];
      const matches: Map<string, string> = DedupeService.findMatches(existing, incoming);
      // URL 键相同 ⇒ 跨源合并到先入库的主条（标题无关）。
      expect(matches.size).assertEqual(1);
      expect(rootOf(matches, 'b1')).assertEqual('a1');
      // 键不同的不动。
      expect(rootOf(matches, 'b2')).assertEqual('');
    });

    it('plan_match_by_title_within_window', 0, () => {
      const existing: DedupeCandidate[] = [at('a1', 'f1', '', 'https://a.example/p', 'same-title', T0)];
      const incoming: DedupeCandidate[] = [
        // 链接不同、标题键相同、时间差 1 小时 ⇒ 命中。
        at('b1', 'f2', '', 'https://b.example/q', 'same-title', T0 + HOUR_MS),
        // 标题相同但差 25 小时 ⇒ 不命中。
        at('b2', 'f3', '', 'https://c.example/r', 'same-title', T0 + DAY_MS + HOUR_MS),
        // 时间窗内但标题不同 ⇒ 不命中。
        at('b3', 'f4', '', 'https://d.example/s', 'other-title', T0)
      ];
      const matches: Map<string, string> = DedupeService.findMatches(existing, incoming);
      expect(matches.size).assertEqual(1);
      expect(rootOf(matches, 'b1')).assertEqual('a1');
      expect(rootOf(matches, 'b2')).assertEqual('');
      expect(rootOf(matches, 'b3')).assertEqual('');
    });

    it('plan_title_window_boundary_matches', 0, () => {
      const existing: DedupeCandidate[] = [at('a1', 'f1', '', 'k-a1', 'same-title', T0)];
      // 正好 ±24h 边界算同一篇；多 1ms 不算。
      const edge: DedupeCandidate[] = [at('b1', 'f2', '', 'k-b1', 'same-title', T0 + DAY_MS)];
      expect(DedupeService.findMatches(existing, edge).size).assertEqual(1);
      const beyond: DedupeCandidate[] = [at('b2', 'f2', '', 'k-b2', 'same-title', T0 + DAY_MS + 1)];
      expect(DedupeService.findMatches(existing, beyond).size).assertEqual(0);
    });

    it('plan_same_feed_never_merges', 0, () => {
      // 同源重复交给既有 id 去重，跨源去重不得介入。
      const existing: DedupeCandidate[] = [at('a1', 'f1', '', 'https://example.com/p', 'same-title')];
      const incoming: DedupeCandidate[] = [
        at('b1', 'f1', '', 'https://example.com/p', 'same-title')
      ];
      const matches: Map<string, string> = DedupeService.findMatches(existing, incoming);
      expect(matches.size).assertEqual(0);
      expect(rootOf(matches, 'b1')).assertEqual('');
    });

    it('plan_duplicate_resolves_to_root_main', 0, () => {
      // a2 已挂在 a1 下（历史重复项）；新来的 b1 命中 a2 时必须挂到根 a1。
      const existing: DedupeCandidate[] = [
        at('a1', 'f1', '', 'L-root', 'T-root'),
        at('a2', 'f2', 'a1', 'L-dup', 'T-dup'),
        // 再深一跳：a3 → a2 → a1。
        at('a3', 'f3', 'a2', 'L-deep', 'T-deep')
      ];
      const incoming: DedupeCandidate[] = [
        at('b1', 'f4', '', 'L-dup', 'T-b1'),
        at('b2', 'f5', '', 'L-deep', 'T-b2')
      ];
      const matches: Map<string, string> = DedupeService.findMatches(existing, incoming);
      expect(rootOf(matches, 'b1')).assertEqual('a1');
      expect(rootOf(matches, 'b2')).assertEqual('a1');
      // 已经是主条的不产生「挂到自己」的条目。
      expect(rootOf(matches, 'a1')).assertEqual('');
      expect(matches.size).assertEqual(2);
    });

    it('plan_resolve_root_stops_at_main_and_handles_missing', 0, () => {
      const byId: Map<string, DedupeCandidate> = new Map<string, DedupeCandidate>();
      byId.set('a1', at('a1', 'f1', ''));
      byId.set('a2', at('a2', 'f2', 'a1'));
      byId.set('a3', at('a3', 'f3', 'a2'));
      expect(DedupeService.resolveRoot('a3', byId)).assertEqual('a1');
      expect(DedupeService.resolveRoot('a1', byId)).assertEqual('a1');
      // 未知 id / 空 id：不抛异常。
      expect(DedupeService.resolveRoot('missing', byId)).assertEqual('missing');
      expect(DedupeService.resolveRoot('', byId)).assertEqual('');
    });

    it('plan_single_match_per_incoming_url_first', 0, () => {
      // URL 能命中时不再看标题，且一条 incoming 只登记一次结果。
      const existing: DedupeCandidate[] = [
        at('a1', 'f1', '', 'L-shared', 'T-one'),
        // 另一个源也收录了同一链接：第一个命中即为结果。
        at('a9', 'f9', '', 'L-shared', 'T-two')
      ];
      const incoming: DedupeCandidate[] = [at('b1', 'f2', '', 'L-shared', 'T-one')];
      const matches: Map<string, string> = DedupeService.findMatches(existing, incoming);
      expect(matches.size).assertEqual(1);
      expect(rootOf(matches, 'b1')).assertEqual('a1');
    });

    it('plan_batch_second_incoming_joins_first', 0, () => {
      // 库里没有候选：本批第一篇成为主条，第二篇并入第一篇。
      const incoming: DedupeCandidate[] = [
        at('b1', 'f2', '', 'https://example.com/p', 'same-title'),
        at('b2', 'f3', '', 'https://example.com/p', 'same-title')
      ];
      const matches: Map<string, string> = DedupeService.findMatches([], incoming);
      expect(matches.size).assertEqual(1);
      expect(rootOf(matches, 'b1')).assertEqual('');
      expect(rootOf(matches, 'b2')).assertEqual('b1');
    });

    it('plan_batch_third_incoming_chains_to_first', 0, () => {
      // 三篇同批：第二、第三都挂到第一篇（不允许 B→C 的二级挂靠）。
      const incoming: DedupeCandidate[] = [
        at('b1', 'f2', '', 'https://example.com/p', 'same-title'),
        at('b2', 'f3', '', 'https://example.com/p', 'same-title'),
        at('b3', 'f4', '', 'https://example.com/p', 'same-title')
      ];
      const matches: Map<string, string> = DedupeService.findMatches([], incoming);
      expect(matches.size).assertEqual(2);
      expect(rootOf(matches, 'b2')).assertEqual('b1');
      expect(rootOf(matches, 'b3')).assertEqual('b1');
    });

    it('plan_empty_inputs', 0, () => {
      expect(DedupeService.findMatches([], []).size).assertEqual(0);
      // 空键候选不参与匹配，也不报错。
      const blank: DedupeCandidate[] = [at('b1', 'f2', '', '', '')];
      const existing: DedupeCandidate[] = [at('a1', 'f1', '', '', '')];
      expect(DedupeService.findMatches(existing, blank).size).assertEqual(0);
    });

    // ---------- pickPromotion ----------

    it('pickPromotion_earliest_published', 0, () => {
      const group: DedupeCandidate[] = [
        at('a2', 'f2', '', 'L2', 'T', T0 + HOUR_MS),
        at('a1', 'f1', '', 'L1', 'T', T0),
        at('a3', 'f3', '', 'L3', 'T', T0 + 2 * HOUR_MS)
      ];
      // 发布时间最早者成为新主条（先发布 = 更接近原文）。
      expect(DedupeService.pickPromotion(group)).assertEqual('a1');
    });

    it('pickPromotion_missing_time_is_latest', 0, () => {
      // publishedAt = 0 表示未知，视为最晚，优先选有明确时间的。
      const group: DedupeCandidate[] = [
        at('a1', 'f1', '', 'L1', 'T', 0),
        at('a2', 'f2', '', 'L2', 'T', T0)
      ];
      expect(DedupeService.pickPromotion(group)).assertEqual('a2');
      // 全部未知 ⇒ 取第一个（保持可预测）。
      const unknown: DedupeCandidate[] = [
        at('a1', 'f1', '', 'L1', 'T', 0),
        at('a2', 'f2', '', 'L2', 'T', 0)
      ];
      expect(DedupeService.pickPromotion(unknown)).assertEqual('a1');
    });

    it('pickPromotion_empty_list', 0, () => {
      expect(DedupeService.pickPromotion([])).assertEqual('');
      // 全是空 id 同样返回空串。
      expect(DedupeService.pickPromotion([at('', 'f1', '', 'L1', 'T')])).assertEqual('');
    });

    // ---------- 幂等 ----------

    it('plan_idempotent_repeated_calls', 0, () => {
      const existing: DedupeCandidate[] = [
        at('a1', 'f1', '', 'L-shared', 'T-one'),
        at('a2', 'f2', 'a1', 'L-dup', 'T-two')
      ];
      const incoming: DedupeCandidate[] = [
        at('b1', 'f3', '', 'L-shared', 'T-one'),
        at('b2', 'f4', '', 'L-dup', 'T-two'),
        at('b3', 'f5', '', 'L-none', 'T-none')
      ];
      const first: Map<string, string> = DedupeService.findMatches(existing, incoming);
      const second: Map<string, string> = DedupeService.findMatches(existing, incoming);
      // 纯函数：重复调用规模与每条结果都不变（不累积副作用）。
      expect(first.size).assertEqual(second.size);
      expect(rootOf(first, 'b1')).assertEqual(rootOf(second, 'b1'));
      expect(rootOf(first, 'b2')).assertEqual(rootOf(second, 'b2'));
      expect(rootOf(first, 'b3')).assertEqual(rootOf(second, 'b3'));
      expect(first.size).assertEqual(2);
      // 入参对象未被改写（canonicalId 仍为空）。
      expect(incoming[0].canonicalId).assertEqual('');
      expect(incoming[1].canonicalId).assertEqual('');
      // 主条提升决策同样幂等。
      expect(DedupeService.pickPromotion(existing)).assertEqual(DedupeService.pickPromotion(existing));
    });
  });
}
