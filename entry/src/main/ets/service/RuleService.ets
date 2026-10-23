/*
 * RuleService.ets — 对「新入库文章」执行规则（编排层：引擎 + 各 Store）。
 *
 * 数据流：应用启用规则 → RuleEngine.plan → 批量写库（已读 / 收藏 / 隐藏 / 打标签）
 *        → 累加规则命中统计 → 回写内存 Article 的可观察字段 → 返回结果。
 *
 * 约束：
 *   - **不 import FeedViewModel / RemoteSyncService**（否则形成循环依赖）；
 *     规则导致的已读 / 收藏由调用方拿到 RuleApplyResult 后自行入队远端同步；
 *   - 任何异常都只记日志并返回空结果：规则失败绝不能影响文章入库与阅读主链路。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { Rule, RuleApplyResult, RulePlan, RuleTestResult } from '../model/Rule';
import { RuleConstants } from '../common/constants/RssConstants';
import { articleStore } from './ArticleStore';
import { dedupeService } from './DedupeService';
import { ruleStore } from './RuleStore';
import { matches, plan } from './RuleEngine';

const DOMAIN: number = 0x0000;
const TAG: string = 'RuleService';

/** 按主条去重后的命中统计（同一合并组只累计一次）。 */
class RuleHitTally {
  /** 规则 id → 去重后的命中篇数（按主条计）。 */
  readonly hits: Map<string, number>;
  /** 命中任意规则的合并组数。 */
  readonly matched: number;

  constructor(hits: Map<string, number>, matched: number) {
    this.hits = hits;
    this.matched = matched;
  }
}

export class RuleService {
  /**
   * 对一批刚入库的文章执行全部启用规则。
   *
   * 幂等：同一篇文章被多条规则命中时动作只执行一次；标签关联走 INSERT OR IGNORE。
   * 返回值只包含本批真正命中的 id（调用方可据此入队远端同步 / 刷新列表）。
   */
  async applyToNew(articles: Article[]): Promise<RuleApplyResult> {
    if (articles.length === 0) {
      return RuleApplyResult.empty();
    }
    try {
      const rules: Rule[] = await ruleStore.list();
      if (rules.length === 0) {
        return RuleApplyResult.empty();
      }
      const result: RulePlan = plan(rules, articles);
      if (result.isEmpty() && result.matched === 0) {
        return RuleApplyResult.empty();
      }
      // 0) 动作前把计划 id 展开成「组 id」：命中主条即作用于整组（FR-013），
      //    命中重复项也先解析到根主条，保证组内状态与标签一致。
      const readIds: string[] = await dedupeService.expandIds(result.readIds);
      const starredIds: string[] = await dedupeService.expandIds(result.starredIds);
      const hiddenIds: string[] = await dedupeService.expandIds(result.hiddenIds);
      // 1) 批量状态动作（逐条 UPDATE，与用户手动批量操作的语义一致）。
      if (readIds.length > 0) {
        articleStore.setReadMany(readIds, true);
      }
      if (starredIds.length > 0) {
        articleStore.setStarredMany(starredIds, true);
      }
      if (hiddenIds.length > 0) {
        articleStore.setHiddenMany(hiddenIds, true);
      }
      // 2) 标签动作（每个标签一次事务，重复添加不产生重复关联；applyTag 内部再展开一次，幂等）。
      for (let i = 0; i < result.tagIds.length; i += 1) {
        const tagId: string = result.tagIds[i];
        const ids: string[] | undefined = result.tagHits.get(tagId);
        if (ids !== undefined && ids.length > 0) {
          await dedupeService.applyTag(tagId, ids);
        }
      }
      // 3) 命中统计：同一合并组只累计一次（按主条计），避免重复项让命中数虚增。
      const tally: RuleHitTally = RuleService.tallyHits(rules, articles);
      if (tally.hits.size > 0) {
        await ruleStore.recordHits(tally.hits, Date.now());
      }
      // 4) 回写内存实例：列表 / 未读数立即正确，不必等下一次读库。
      this.applyInMemory(articles, result);
      return new RuleApplyResult(readIds, starredIds, hiddenIds, tally.matched);
    } catch (err) {
      const error: Error = err as Error;
      hilog.error(DOMAIN, TAG, 'applyToNew failed: %{public}s', error.message);
      return RuleApplyResult.empty();
    }
  }

  /**
   * 试运行：读最近 limit 篇文章，只用引擎统计命中数，**不写任何状态**。
   * limit <= 0 时退回 RuleConstants.RULE_TEST_SAMPLE。
   */
  async testRun(ruleId: string, limit: number): Promise<RuleTestResult> {
    if (ruleId.length === 0) {
      return new RuleTestResult(0, 0);
    }
    try {
      const rules: Rule[] = await ruleStore.list();
      let target: Rule | undefined = undefined;
      for (let i = 0; i < rules.length; i += 1) {
        if (rules[i].id === ruleId) {
          target = rules[i];
          break;
        }
      }
      if (target === undefined) {
        return new RuleTestResult(0, 0);
      }
      const sampleSize: number = limit > 0 ? limit : RuleConstants.RULE_TEST_SAMPLE;
      const sample: Article[] = await ruleStore.sampleArticles(sampleSize);
      let matched: number = 0;
      for (let i = 0; i < sample.length; i += 1) {
        if (matches(target, sample[i])) {
          matched += 1;
        }
      }
      return new RuleTestResult(sample.length, matched);
    } catch (err) {
      const error: Error = err as Error;
      hilog.error(DOMAIN, TAG, 'testRun failed: %{public}s', error.message);
      return new RuleTestResult(0, 0);
    }
  }

  /**
   * 命中统计（按主条去重）：同一条规则命中同一合并组的多篇（主条 + 重复项）时只计一次。
   * 组 id 取文章的 canonicalId（空串表示自己是主条），因此不需要额外查库。
   */
  private static tallyHits(rules: Rule[], articles: Article[]): RuleHitTally {
    const rootById: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < articles.length; i += 1) {
      const article: Article = articles[i];
      const root: string = article.canonicalId.length > 0 ? article.canonicalId : article.id;
      rootById.set(article.id, root);
    }
    const hits: Map<string, number> = new Map<string, number>();
    const matchedRoots: Set<string> = new Set<string>();
    for (let r = 0; r < rules.length; r += 1) {
      const rule: Rule = rules[r];
      if (!rule.enabled) {
        continue;
      }
      const seen: Set<string> = new Set<string>();
      for (let a = 0; a < articles.length; a += 1) {
        const article: Article = articles[a];
        if (!matches(rule, article)) {
          continue;
        }
        const found: string | undefined = rootById.get(article.id);
        const root: string = found === undefined ? article.id : found;
        seen.add(root);
        matchedRoots.add(root);
      }
      if (seen.size > 0) {
        hits.set(rule.id, seen.size);
      }
    }
    return new RuleHitTally(hits, matchedRoots.size);
  }

  /** 把计划里的状态回写到内存 Article（去重集合，避免 O(n²) 查找）。 */
  private applyInMemory(articles: Article[], result: RulePlan): void {
    const readSet: Set<string> = new Set<string>();
    const starredSet: Set<string> = new Set<string>();
    const hiddenSet: Set<string> = new Set<string>();
    for (let i = 0; i < result.readIds.length; i += 1) {
      readSet.add(result.readIds[i]);
    }
    for (let i = 0; i < result.starredIds.length; i += 1) {
      starredSet.add(result.starredIds[i]);
    }
    for (let i = 0; i < result.hiddenIds.length; i += 1) {
      hiddenSet.add(result.hiddenIds[i]);
    }
    for (let i = 0; i < articles.length; i += 1) {
      const article: Article = articles[i];
      if (readSet.has(article.id)) {
        article.read = true;
      }
      if (starredSet.has(article.id)) {
        article.starred = true;
      }
      if (hiddenSet.has(article.id)) {
        article.hidden = true;
      }
    }
  }
}

/** 全局唯一实例。 */
export const ruleService: RuleService = new RuleService();
