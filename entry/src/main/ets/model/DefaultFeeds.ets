/*
 * DefaultFeeds.ets — 首次启动时的内置订阅源种子数据。
 *
 * 只是数据（订阅地址 + 展示标题），不是界面文案，因此放在 model 层；抓取成功后标题会被
 * feed 自身的标题覆盖。用户删除后不会再被写回（只在偏好库为空时播种）。
 */
export class FeedSeed {
  readonly title: string;
  readonly url: string;

  constructor(title: string, url: string) {
    this.title = title;
    this.url = url;
  }
}

/** 内置订阅源。 */
export const DEFAULT_FEEDS: FeedSeed[] = [
  new FeedSeed('少数派', 'https://sspai.com/feed'),
  new FeedSeed('Hacker News', 'https://hnrss.org/frontpage')
];
