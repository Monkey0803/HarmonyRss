/*
 * NotifyPolicy.test.ets — 通知策略纯函数单测。
 *
 * 覆盖：
 *   - 免打扰：普通时段、跨午夜、起止相同视为关闭、边界分钟；
 *   - 关键词：大小写不敏感、标题 / 摘要命中、空列表放行、中文关键词；
 *   - 过滤：已读 / 隐藏 / 跨源重复 / 源停用 / 源通知关闭 / 关键词不命中；
 *   - 规划：每源上限、总量上限与溢出计数；
 *   - 摘要：未到点 / 当天已发 / 次日到期；
 *   - 归一化：关键词去重与截断、分钟数夹取、稳定通知 id。
 *
 * 全部用例只依赖纯函数，不打开数据库、不发网络请求。
 */

import { describe, it, expect } from '@ohos/hypium';
import { Article, FeedSource } from '../../../main/ets/model/Feed';
import { NotifyPolicy, NotifyPlan } from '../../../main/ets/model/Notify';
import { CommonConstants } from '../../../main/ets/common/constants/CommonConstants';
import { TriState } from '../../../main/ets/common/constants/SettingsConstants';
import {
  clampDigestHour,
  clampMinuteOfDay,
  digestDue,
  filter,
  groupNameOf,
  inDnd,
  localDateKey,
  matchesKeywords,
  normalizeKeywords,
  plan,
  stableNotificationId
} from '../../../main/ets/service/NotifyPolicy';

/** 构造一篇文章（只填策略判定用得到的字段）。 */
function article(id: string, feedId: string, title: string, summary: string): Article {
  return new Article(id, feedId, 'Feed ' + feedId, title, 'https://example.com/' + id, summary, '', 0);
}

/** 构造一个订阅源。 */
function feed(id: string): FeedSource {
  return new FeedSource(id, 'Feed ' + id, 'https://example.com/' + id + '.xml', 'https://example.com');
}

/** 默认策略：免打扰关闭，避免其他用例被时段影响。 */
function policyOf(dndEnabled: boolean, start: number, end: number, digestEnabled: boolean,
  digestHour: number, keywords: string[]): NotifyPolicy {
  return new NotifyPolicy(dndEnabled, start, end, digestEnabled, digestHour, keywords);
}

export default function notifyPolicyTest() {
  describe('NotifyPolicy', () => {
    // ---------- 免打扰 ----------

    it('inDnd_same_day_range', 0, () => {
      // 12:00–14:00：区间内命中，边界左闭右开。
      const policy: NotifyPolicy = policyOf(true, 12 * 60, 14 * 60, false, 20, []);
      expect(inDnd(policy, 12 * 60)).assertTrue();
      expect(inDnd(policy, 13 * 60 + 59)).assertTrue();
      expect(inDnd(policy, 14 * 60)).assertFalse();
      expect(inDnd(policy, 11 * 60 + 59)).assertFalse();
    });

    it('inDnd_cross_midnight_range', 0, () => {
      // 默认 23:00–08:00：跨午夜时 [start, 24:00) 与 [0, end) 都命中。
      const policy: NotifyPolicy = policyOf(true, 23 * 60, 8 * 60, false, 20, []);
      expect(inDnd(policy, 23 * 60)).assertTrue();
      expect(inDnd(policy, 23 * 60 + 30)).assertTrue();
      expect(inDnd(policy, 0)).assertTrue();
      expect(inDnd(policy, 7 * 60 + 59)).assertTrue();
      expect(inDnd(policy, 8 * 60)).assertFalse();
      expect(inDnd(policy, 12 * 60)).assertFalse();
    });

    it('inDnd_same_start_end_disables', 0, () => {
      // 起止相同无法表达区间，按「关闭」处理，避免全天静音。
      const policy: NotifyPolicy = policyOf(true, 8 * 60, 8 * 60, false, 20, []);
      expect(inDnd(policy, 8 * 60)).assertFalse();
      expect(inDnd(policy, 0)).assertFalse();
      expect(inDnd(policy, 23 * 60)).assertFalse();
    });

    it('inDnd_disabled_flag_wins', 0, () => {
      const policy: NotifyPolicy = policyOf(false, 0, 1439, false, 20, []);
      expect(inDnd(policy, 12 * 60)).assertFalse();
    });

    // ---------- 关键词 ----------

    it('matchesKeywords_case_insensitive', 0, () => {
      const item: Article = article('a1', 'f1', 'AI Weekly Digest', 'A summary about models');
      expect(matchesKeywords(item, ['ai'])).assertTrue();
      expect(matchesKeywords(item, ['WEEKLY'])).assertTrue();
      expect(matchesKeywords(item, ['models'])).assertTrue();
      expect(matchesKeywords(item, ['blockchain'])).assertFalse();
    });

    it('matchesKeywords_empty_list_passes', 0, () => {
      const item: Article = article('a1', 'f1', 'Hello', 'World');
      expect(matchesKeywords(item, [])).assertTrue();
    });

    it('matchesKeywords_chinese', 0, () => {
      const item: Article = article('a1', 'f1', '鸿蒙生态进展', '本周 HarmonyOS 更新');
      expect(matchesKeywords(item, ['鸿蒙'])).assertTrue();
      expect(matchesKeywords(item, ['生态'])).assertTrue();
      expect(matchesKeywords(item, ['安卓'])).assertFalse();
    });

    it('normalizeKeywords_dedupes_and_truncates', 0, () => {
      // 去首尾空白、大小写不敏感去重、保持原始大小写与顺序。
      const result: string[] = normalizeKeywords([' AI ', 'ai', '鸿蒙', '', '鸿蒙 ']);
      expect(result.length).assertEqual(2);
      expect(result[0]).assertEqual('AI');
      expect(result[1]).assertEqual('鸿蒙');
      // 超过上限时只保留前 N 个。
      const many: string[] = [];
      for (let i = 0; i < CommonConstants.NOTIFY_KEYWORD_MAX + 5; i += 1) {
        many.push('k' + i.toString());
      }
      expect(normalizeKeywords(many).length).assertEqual(CommonConstants.NOTIFY_KEYWORD_MAX);
    });

    // ---------- 过滤 ----------

    it('filter_drops_read_hidden_duplicate', 0, () => {
      const feeds: FeedSource[] = [feed('f1')];
      feeds[0].notify = TriState.ON;
      const read: Article = article('a1', 'f1', 'Read', '');
      read.read = true;
      const hidden: Article = article('a2', 'f1', 'Hidden', '');
      hidden.hidden = true;
      const duplicate: Article = article('a3', 'f1', 'Duplicate', '');
      duplicate.canonicalId = 'a0';
      const keep: Article = article('a4', 'f1', 'Keep', '');
      const result: Article[] = filter([read, hidden, duplicate, keep], feeds, policyOf(false, 0, 0, false, 20, []));
      expect(result.length).assertEqual(1);
      expect(result[0].id).assertEqual('a4');
    });

    it('filter_respects_feed_switch_and_enabled', 0, () => {
      const on: FeedSource = feed('f1');
      on.notify = TriState.ON;
      const off: FeedSource = feed('f2');
      off.notify = TriState.OFF;
      const disabled: FeedSource = feed('f3');
      disabled.notify = TriState.ON;
      disabled.enabled = false;
      const items: Article[] = [
        article('a1', 'f1', 'One', ''),
        article('a2', 'f2', 'Two', ''),
        article('a3', 'f3', 'Three', ''),
        article('a4', 'missing', 'Four', '')
      ];
      const result: Article[] = filter(items, [on, off, disabled], policyOf(false, 0, 0, false, 20, []));
      expect(result.length).assertEqual(1);
      expect(result[0].id).assertEqual('a1');
    });

    it('filter_applies_keywords', 0, () => {
      const feeds: FeedSource[] = [feed('f1')];
      feeds[0].notify = TriState.ON;
      const hit: Article = article('a1', 'f1', 'AI news', '');
      const miss: Article = article('a2', 'f1', 'Sports', '');
      const result: Article[] = filter([hit, miss], feeds, policyOf(false, 0, 0, false, 20, ['ai']));
      expect(result.length).assertEqual(1);
      expect(result[0].id).assertEqual('a1');
    });

    // ---------- 规划与分组 ----------

    it('plan_caps_per_feed_and_total', 0, () => {
      const items: Article[] = [];
      // 2 个源，每源 5 篇：每源最多 3 条、总计最多 5 条。
      for (let f = 0; f < 2; f += 1) {
        for (let i = 0; i < 5; i += 1) {
          items.push(article('a' + f.toString() + '_' + i.toString(), 'f' + f.toString(), 'T', ''));
        }
      }
      const planned: NotifyPlan = plan(items, 3, 5);
      // f0 先占满每源 3 条，f1 只能再进 2 条 → 总量上限生效。
      expect(planned.items.length).assertEqual(5);
      expect(planned.total).assertEqual(5);
      expect(planned.overflowByFeed.get('f0')).assertEqual(2);
      expect(planned.overflowByFeed.get('f1')).assertEqual(3);
    });

    it('plan_zero_limits_overflow_all', 0, () => {
      const items: Article[] = [
        article('a1', 'f1', 'One', ''),
        article('a2', 'f2', 'Two', '')
      ];
      const planned: NotifyPlan = plan(items, 0, 0);
      expect(planned.items.length).assertEqual(0);
      expect(planned.overflowByFeed.get('f1')).assertEqual(1);
      expect(planned.overflowByFeed.get('f2')).assertEqual(1);
    });

    it('group_name_and_stable_id', 0, () => {
      expect(groupNameOf('f1')).assertEqual('feed_f1');
      const first: number = stableNotificationId('article-1');
      const again: number = stableNotificationId('article-1');
      const other: number = stableNotificationId('article-2');
      expect(first).assertEqual(again);
      expect(first === other).assertFalse();
      expect(first > 0).assertTrue();
    });

    // ---------- 摘要 ----------

    it('digestDue_checks_hour_and_date', 0, () => {
      const policy: NotifyPolicy = policyOf(false, 0, 0, true, 20, []);
      const at19: number = new Date(2026, 9, 26, 19, 30, 0, 0).getTime();
      const at20: number = new Date(2026, 9, 26, 20, 0, 0, 0).getTime();
      expect(digestDue(policy, at19, '')).assertFalse();
      expect(digestDue(policy, at20, '')).assertTrue();
      // 当天已发过 → 不再发。
      expect(digestDue(policy, at20, localDateKey(at20))).assertFalse();
      // 次日到了设定时间 → 又可以发。
      const nextDay: number = new Date(2026, 9, 27, 20, 0, 0, 0).getTime();
      expect(digestDue(policy, nextDay, localDateKey(at20))).assertTrue();
    });

    it('digestDue_disabled', 0, () => {
      const policy: NotifyPolicy = policyOf(false, 0, 0, false, 20, []);
      const at20: number = new Date(2026, 9, 26, 20, 0, 0, 0).getTime();
      expect(digestDue(policy, at20, '')).assertFalse();
    });

    // ---------- 归一化 ----------

    it('clamp_helpers', 0, () => {
      expect(clampMinuteOfDay(-10, 0)).assertEqual(0);
      expect(clampMinuteOfDay(2000, 0)).assertEqual(1439);
      expect(clampMinuteOfDay(Number.NaN, 480)).assertEqual(480);
      expect(clampDigestHour(30, 20)).assertEqual(23);
      expect(clampDigestHour(-1, 20)).assertEqual(0);
      expect(clampDigestHour(Number.NaN, 20)).assertEqual(20);
    });
  });
}
