/*
 * FilterSegmentBar.ets — 阅读页签标题栏上的「全部 / 未读 / 收藏 / 稍后读 / 归档」筛选条。
 *
 * 位置：挂在 HdsNavigation 标题栏的 bottomBuilder 上（不是内容区）——沉浸光感是区域级能力，
 * 只有 Navigation/NavDestination 标题栏与横向 Tabs 底部 TabBar 里组件才真正吃到系统材质，
 * 放内容区只会打 "Material inactive: out of scope"。
 *
 * 胶囊本体与分段视觉在 views/FilterCapsule.ets（搜索页复用同一个组件，保证两处观感一致），
 * 这里只负责：筛选顺序、文案，以及把选中状态接到 FeedViewModel。
 *
 * 「全部已读」不在这里：它是批量动作而不是筛选项，放在内容区表头紧贴「N 未读」计数
 * （见 views/HomeTabView.ets），筛选胶囊只留筛选。
 *
 * 用全局 @Builder 而不是自定义组件：纯展示、无生命周期需求
 * （CodeLinter @performance/avoid-overusing-custom-component-check）。
 */

import { feedViewModel } from '../viewmodel/FeedViewModel';
import { ArticleFilter } from '../common/constants/RssConstants';
import { FilterCapsule } from './FilterCapsule';

/** 分段的顺序：新增筛选项时同步补文案（与 FILTER_LABELS 一一对应）。 */
const FILTER_ORDER: string[] = [
  ArticleFilter.ALL,
  ArticleFilter.UNREAD,
  ArticleFilter.STARRED,
  ArticleFilter.SAVED,
  ArticleFilter.ARCHIVED
];

/** 与 FILTER_ORDER 逐项对应的文案。 */
const FILTER_LABELS: ResourceStr[] = [
  $r('app.string.filter_all'),
  $r('app.string.filter_unread'),
  $r('app.string.filter_starred'),
  $r('app.string.filter_saved'),
  $r('app.string.filter_archived')
];

/** 标题栏 bottomBuilder：筛选胶囊。 */
@Builder
export function FilterSegmentBar() {
  Row() {
    FilterCapsule({
      options: FILTER_ORDER,
      labels: FILTER_LABELS,
      active: feedViewModel.filter,
      onTitleBar: true,
      onSelect: (value: string) => {
        feedViewModel.setFilter(value);
      }
    })
  }
  .width('100%')
  .height('100%')
  .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
  .alignItems(VerticalAlign.Center)
}
