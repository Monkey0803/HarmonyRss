/*
 * Diagnostics.test.ets — 诊断纯逻辑单测。
 *
 * 覆盖：抓取失败五类归因、上次退出原因语义分类、最慢源排序与平均耗时。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  averageDuration,
  ExitReasonKind,
  exitReasonKind,
  failureCategoryOf,
  FeedFetchSample,
  FetchFailureCategory,
  topSlowFeeds
} from '../../../main/ets/model/Diagnostics';
import { FeedError } from '../../../main/ets/common/constants/RssConstants';

export default function diagnosticsTest() {
  describe('Diagnostics', () => {
    it('failure_category_mapping', 0, () => {
      expect(failureCategoryOf(FeedError.TIMEOUT)).assertEqual(FetchFailureCategory.TIMEOUT);
      expect(failureCategoryOf(FeedError.NETWORK_ERROR)).assertEqual(FetchFailureCategory.NETWORK);
      expect(failureCategoryOf(FeedError.HTTP_ERROR)).assertEqual(FetchFailureCategory.HTTP);
      expect(failureCategoryOf(FeedError.PARSE_ERROR)).assertEqual(FetchFailureCategory.CONTENT);
      expect(failureCategoryOf(FeedError.NOT_A_FEED)).assertEqual(FetchFailureCategory.CONTENT);
      expect(failureCategoryOf(FeedError.EMPTY_RESPONSE)).assertEqual(FetchFailureCategory.CONTENT);
      expect(failureCategoryOf(FeedError.FETCH_FAILED)).assertEqual(FetchFailureCategory.OTHER);
      expect(failureCategoryOf(FeedError.NONE)).assertEqual(FetchFailureCategory.OTHER);
    });

    it('exit_reason_mapping', 0, () => {
      expect(exitReasonKind(0)).assertEqual(ExitReasonKind.UNKNOWN);
      expect(exitReasonKind(2)).assertEqual(ExitReasonKind.NORMAL);
      expect(exitReasonKind(3)).assertEqual(ExitReasonKind.CPP_CRASH);
      expect(exitReasonKind(4)).assertEqual(ExitReasonKind.JS_ERROR);
      expect(exitReasonKind(5)).assertEqual(ExitReasonKind.FREEZE);
      expect(exitReasonKind(6)).assertEqual(ExitReasonKind.RESOURCE);
      expect(exitReasonKind(7)).assertEqual(ExitReasonKind.RESOURCE);
      expect(exitReasonKind(8)).assertEqual(ExitReasonKind.UPGRADE);
      expect(exitReasonKind(9)).assertEqual(ExitReasonKind.USER);
      expect(exitReasonKind(10)).assertEqual(ExitReasonKind.USER);
      expect(exitReasonKind(99)).assertEqual(ExitReasonKind.OTHER);
    });

    it('top_slow_feeds', 0, () => {
      const samples: FeedFetchSample[] = [
        new FeedFetchSample('a', 'A', 30, true, ''),
        new FeedFetchSample('b', 'B', 120, false, FeedError.TIMEOUT),
        new FeedFetchSample('c', 'C', 70, true, ''),
        new FeedFetchSample('d', 'D', 200, true, '')
      ];
      const top = topSlowFeeds(samples, 3);
      expect(top.length).assertEqual(3);
      expect(top[0].feedId).assertEqual('d');
      expect(top[1].feedId).assertEqual('b');
      expect(top[2].feedId).assertEqual('c');
      expect(topSlowFeeds(samples, 0).length).assertEqual(0);
    });

    it('average_duration', 0, () => {
      expect(averageDuration(300, 3)).assertEqual(100);
      expect(averageDuration(0, 0)).assertEqual(0);
      expect(averageDuration(100, 0)).assertEqual(0);
      expect(averageDuration(0, 3)).assertEqual(0);
    });
  });
}
