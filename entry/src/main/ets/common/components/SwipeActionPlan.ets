/*
 * SwipeActionPlan.ets — 列表左滑「更多」菜单的条目规则（纯数据，不依赖 ArkUI 渲染，可在 ohosTest 直接测）。
 *
 * 背景：左滑原先平铺 7 个动作（下载/重试、清除离线、分享、收藏、稍后读、只看该源、已读切换），
 * 单个文案块约 52vp，360vp 屏上列表项可用宽度只有约 328vp —— 后面两项直接跑出屏幕且无法触达。
 * 收口成「4 个直达块（分享 / 稍后读 / 已读 / 更多）+ 更多菜单」之后，哪些动作进菜单、
 * 按什么顺序、在哪种离线态出现，全部收敛到这里；
 * 渲染层（ArticleSwipeBar）只负责把 id 翻译成文案 / 图标 / 危险色。
 *
 * 菜单只放低频动作：离线动作 + 「只看该源」。
 * 分享不在菜单里 —— 它是直达块；收藏也不在左滑 —— 行内星标已经覆盖，同一动作不做两处入口。
 *
 * 离线分支语义与阅读页 `ArticleDetailView.actionsMenuSpec` 保持一致：
 * 未缓存才有「下载」，只抓到文本 / 部分图片时给「重试」，只要存过就有「清除」。
 */

/** 「更多」菜单条目 id；与渲染层的 MenuItemSpec.id 一一对应（菜单内必须唯一）。 */
export enum SwipeOverflowId {
  DOWNLOAD = 'offline_download',
  RETRY = 'offline_retry',
  CLEAR_OFFLINE = 'offline_clear',
  SCOPE_FEED = 'scope_feed'
}

/** 离线态取值（与 Article.offlineState 一致）。 */
export const OFFLINE_NONE: string = 'none';
export const OFFLINE_TEXT: string = 'text';
export const OFFLINE_PARTIAL: string = 'partial';
export const OFFLINE_FULL: string = 'full';

/** 当前离线态对应的离线条目（顺序即菜单顺序）。 */
export function offlineOverflowIds(offlineState: string): SwipeOverflowId[] {
  if (offlineState === OFFLINE_TEXT || offlineState === OFFLINE_PARTIAL) {
    return [SwipeOverflowId.RETRY, SwipeOverflowId.CLEAR_OFFLINE];
  }
  if (offlineState === OFFLINE_FULL) {
    return [SwipeOverflowId.CLEAR_OFFLINE];
  }
  // 未知 / 'none' 都按「未缓存」处理：宁可给一个点了会重抓的「下载」，也不要空菜单。
  return [SwipeOverflowId.DOWNLOAD];
}

/**
 * 「更多」菜单的完整条目序列：离线动作 → 只看该源。
 *
 * showScopeFeed：首页 true；订阅源详情列表 false（已经是单源视图，再收敛没有意义）。
 */
export function swipeOverflowIds(offlineState: string, showScopeFeed: boolean): SwipeOverflowId[] {
  const ids: SwipeOverflowId[] = [];
  const offline: SwipeOverflowId[] = offlineOverflowIds(offlineState);
  for (let i = 0; i < offline.length; i += 1) {
    ids.push(offline[i]);
  }
  if (showScopeFeed) {
    ids.push(SwipeOverflowId.SCOPE_FEED);
  }
  return ids;
}
