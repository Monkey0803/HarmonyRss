/*
 * FeedStore.ets — 订阅源列表的落盘与恢复（@ohos.data.preferences）。
 *
 * 只存订阅地址等语义数据（JSON 数组），读出来逐条做类型校验，脏数据直接丢弃；
 * 首次运行（读不到值 / 全部非法）时播种内置订阅源。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';
import { FeedSource } from '../model/Feed';
import { DEFAULT_FEEDS, FeedSeed } from '../model/DefaultFeeds';

/** 落盘用的扁平结构。 */
interface FeedRecord {
  title: string;
  url: string;
  siteUrl: string;
  group: string;
}

export class FeedStore {
  private store: preferences.Preferences | undefined = undefined;

  /**
   * 打开偏好库并读出订阅源。
   * seedWhenEmpty = true（默认）：没有有效数据时返回内置种子（首启体验）；
   * false：如实返回空数组（后台任务用，避免用户删光订阅后又被种子写回文章）。
   */
  async load(context: common.Context, seedWhenEmpty: boolean = true): Promise<FeedSource[]> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      this.store = store;
      const raw: preferences.ValueType =
        store.getSync(PreferencesConstants.KEY_RSS_FEEDS, '');
      const text: string = typeof raw === 'string' ? raw : '';
      const stored: FeedSource[] = this.decode(text);
      if (stored.length > 0) {
        return stored;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('FeedStore.load failed: ' + error.code.toString());
    }
    const seeds: FeedSource[] = [];
    if (!seedWhenEmpty) {
      return seeds;
    }
    for (let i = 0; i < DEFAULT_FEEDS.length; i += 1) {
      const seed: FeedSeed = DEFAULT_FEEDS[i];
      seeds.push(new FeedSource(seed.url, seed.title, seed.url, ''));
    }
    return seeds;
  }

  /** 全量写回订阅源。 */
  save(feeds: FeedSource[]): void {
    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return;
    }
    // putSync 标注了可能抛异常，要求调用点 catch：写失败只影响下次启动的恢复。
    try {
      store.putSync(PreferencesConstants.KEY_RSS_FEEDS, this.encode(feeds));
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('FeedStore.putSync failed: ' + error.code.toString());
      return;
    }
    store.flush().catch((err: BusinessError) => {
      console.error('FeedStore.flush failed: ' + err.code.toString());
    });
  }

  private encode(feeds: FeedSource[]): string {
    const records: FeedRecord[] = [];
    for (let i = 0; i < feeds.length; i += 1) {
      const record: FeedRecord = {
        title: feeds[i].title,
        url: feeds[i].url,
        siteUrl: feeds[i].siteUrl,
        group: feeds[i].group
      };
      records.push(record);
    }
    return JSON.stringify(records);
  }

  private decode(text: string): FeedSource[] {
    const feeds: FeedSource[] = [];
    if (text.length === 0) {
      return feeds;
    }
    try {
      const records: FeedRecord[] = JSON.parse(text) as FeedRecord[];
      for (let i = 0; i < records.length; i += 1) {
        const record: FeedRecord = records[i];
        const url: string = typeof record.url === 'string' ? record.url.trim() : '';
        if (url.length === 0) {
          continue;
        }
        const title: string = typeof record.title === 'string' && record.title.length > 0
          ? record.title
          : url;
        const siteUrl: string = typeof record.siteUrl === 'string' ? record.siteUrl : '';
        const group: string = typeof record.group === 'string' ? record.group : '';
        feeds.push(new FeedSource(url, title, url, siteUrl, group));
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('FeedStore.decode failed: ' + error.code.toString());
    }
    return feeds;
  }
}

export const feedStore: FeedStore = new FeedStore();
