/* Pure projection of an ordered article list into V2 list groups. */
import { Article } from '../model/Feed';
import { GroupMode } from '../common/constants/RssConstants';
import { ArticleDataSource, ArticleGroup } from './ArticleDataSource';

const DAY_MS: number = 24 * 60 * 60 * 1000;
const SCRATCH_DATE: Date = new Date();

/**
 * 把（已筛选并排好序的）列表按当前分组方式切分成组。
 * 组顺序沿用列表顺序：按订阅源时是「出现顺序」，按日期时是「时间顺序」。
 */
export function buildArticleGroups(list: Article[], groupMode: string): ArticleGroup[] {
  const order: string[] = [];
  const buckets: Map<string, Article[]> = new Map<string, Article[]>();
  const titles: Map<string, ResourceStr> = new Map<string, ResourceStr>();
  for (let i = 0; i < list.length; i += 1) {
    const item: Article = list[i];
    const key: string = groupMode === GroupMode.FEED
      ? item.feedId
      : dateBucket(item.publishedAt);
    let bucket: Article[] | undefined = buckets.get(key);
    if (bucket === undefined) {
      bucket = [];
      buckets.set(key, bucket);
      order.push(key);
      titles.set(key, groupMode === GroupMode.FEED
        ? item.feedTitle
        : dateBucketTitle(key));
    }
    bucket.push(item);
  }

  const result: ArticleGroup[] = [];
  for (let i = 0; i < order.length; i += 1) {
    const items: Article[] | undefined = buckets.get(order[i]);
    const title: ResourceStr | undefined = titles.get(order[i]);
    if (items === undefined || title === undefined) {
      continue;
    }
    let unread: number = 0;
    for (let j = 0; j < items.length; j += 1) {
      if (!items[j].read) {
        unread += 1;
      }
    }
    const source: ArticleDataSource = new ArticleDataSource();
    source.setItems(items);
    result.push(new ArticleGroup(order[i], title, unread, items.length, source));
  }
  return result;
}

/** 日期桶：今天 / 昨天 / 本周 / 更早（以周一为一周之始）。 */
function dateBucket(ts: number): string {
  const today: number = startOfDay(Date.now());
  if (ts >= today) {
    return 'today';
  }
  if (ts >= today - DAY_MS) {
    return 'yesterday';
  }
  SCRATCH_DATE.setTime(today);
  const weekday: number = (SCRATCH_DATE.getDay() + 6) % 7;
  if (ts >= today - weekday * DAY_MS) {
    return 'this_week';
  }
  return 'earlier';
}

/** 时间戳所在自然日的 00:00。 */
function startOfDay(ts: number): number {
  SCRATCH_DATE.setTime(ts);
  SCRATCH_DATE.setHours(0, 0, 0, 0);
  return SCRATCH_DATE.getTime();
}

/** 日期桶标题。 */
function dateBucketTitle(key: string): ResourceStr {
  if (key === 'today') {
    return $r('app.string.group_today');
  }
  if (key === 'yesterday') {
    return $r('app.string.group_yesterday');
  }
  if (key === 'this_week') {
    return $r('app.string.group_this_week');
  }
  return $r('app.string.group_earlier');
}
