/*
 * FeedRowBuilder.ets — 订阅管理列表的行展开与分组聚合（纯函数，便于单测）。
 *
 * 为什么单独放纯函数：
 *   - FeedViewModel.displayRows 只负责「分组 + 折叠 → 行数组」，便于覆盖分组顺序 / 折叠 / 未分组垫底；
 *   - 组头计数、未读数、组内末行都在渲染时按 @Trace feeds 现算，避免把值预计算进
 *     FeedListItem 后被 ForEach 复用旧节点、导致界面不刷新。
 */

import { FeedGroup, FeedListItem, FeedSource } from '../model/Feed';

/** 组头行用的占位订阅源（永不渲染）。 */
const PLACEHOLDER_FEED: FeedSource = new FeedSource('', '', '', '');

/** 把分组展平成列表行：每个分组先推组头，未折叠时再推组内订阅行。 */
export function buildFeedRows(groups: FeedGroup[], collapsedGroups: string[]): FeedListItem[] {
  const rows: FeedListItem[] = [];
  for (let i = 0; i < groups.length; i += 1) {
    const group: FeedGroup = groups[i];
    const collapsed: boolean = collapsedGroups.indexOf(group.name) >= 0;
    rows.push(new FeedListItem(true, group.name, group.feeds.length, PLACEHOLDER_FEED));
    if (collapsed) {
      continue;
    }
    for (let j = 0; j < group.feeds.length; j += 1) {
      rows.push(new FeedListItem(false, group.name, 0, group.feeds[j]));
    }
  }
  return rows;
}

/** 某分组的订阅源数量（读 @Trace group，任何分组变更都会重算）。 */
export function groupCount(feeds: FeedSource[], name: string): number {
  let count: number = 0;
  for (let i = 0; i < feeds.length; i += 1) {
    if (feeds[i].group === name) {
      count += 1;
    }
  }
  return count;
}

/** 某分组的未读合计（读 @Trace unreadCount，后台同步后组头角标自动更新）。 */
export function groupUnread(feeds: FeedSource[], name: string): number {
  let unread: number = 0;
  for (let i = 0; i < feeds.length; i += 1) {
    if (feeds[i].group === name) {
      unread += feeds[i].unreadCount;
    }
  }
  return unread;
}

/** 该订阅源是否是它所属分组的最后一行（决定卡片底部圆角）。 */
export function isLastFeedInGroup(feeds: FeedSource[], feedId: string): boolean {
  let group: string = '';
  let found: boolean = false;
  for (let i = 0; i < feeds.length; i += 1) {
    if (feeds[i].id === feedId) {
      group = feeds[i].group;
      found = true;
      break;
    }
  }
  if (!found) {
    return false;
  }
  for (let i = feeds.length - 1; i >= 0; i -= 1) {
    if (feeds[i].group === group) {
      return feeds[i].id === feedId;
    }
  }
  return false;
}
