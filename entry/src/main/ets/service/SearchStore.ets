/*
 * SearchStore.ets — 检索入口与搜索历史（偏好库）。
 *
 * 检索本身下沉到 ArticleStore（FTS / LIKE 降级），这里只做：
 *   1. 统一入口（视图 / ViewModel 不直接依赖 SQL 层）；
 *   2. 搜索历史（JSON 字符串数组，最多 20 条、去重、最新在前；读写失败静默降级）。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SearchPage, SearchQuery } from '../model/Search';
import { articleStore } from './ArticleStore';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';
import { SearchConstants } from '../common/constants/RssConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'SearchStore';

export class SearchStore {
  private store: preferences.Preferences | undefined = undefined;
  /** 内存缓存的历史（偏好库读取失败时至少本次会话可用）。 */
  private cachedHistory: string[] = [];

  /** 打开偏好库（搜索页进入时调用一次；失败不影响检索）。 */
  async open(context: common.Context): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      this.cachedHistory = this.decode(
        this.store.getSync(PreferencesConstants.KEY_SEARCH_HISTORY, '') as string);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'open preferences failed: %{public}d', error.code);
    }
  }

  /** 执行检索（分页）。 */
  async search(query: SearchQuery, offset: number, limit: number): Promise<SearchPage> {
    return await articleStore.search(query, offset, limit);
  }

  /** 检索索引是否可用（false 时是 LIKE 降级，功能仍可用）。 */
  isFtsReady(): boolean {
    return articleStore.isFtsReady();
  }

  /** 检索链路是否走索引：主索引（纯英文）或中文索引任一可用即不算降级。 */
  isIndexAvailable(): boolean {
    return articleStore.isFtsReady() || articleStore.isCjkIndexReady();
  }

  /** 最近搜索历史（最新在前）。 */
  history(): string[] {
    return this.cachedHistory.slice();
  }

  /** 记一条搜索历史：去重、最新在前、最多 20 条。 */
  pushHistory(raw: string): void {
    const text: string = raw.trim();
    if (text.length === 0) {
      return;
    }
    const next: string[] = [text];
    for (let i = 0; i < this.cachedHistory.length; i += 1) {
      if (this.cachedHistory[i] !== text && next.length < SearchConstants.HISTORY_MAX) {
        next.push(this.cachedHistory[i]);
      }
    }
    this.cachedHistory = next;
    this.persist();
  }

  /** 清空搜索历史。 */
  clearHistory(): void {
    this.cachedHistory = [];
    this.persist();
  }

  private persist(): void {
    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(PreferencesConstants.KEY_SEARCH_HISTORY, JSON.stringify(this.cachedHistory));
      store.flush().catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'flush history failed: %{public}d', err.code);
      });
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'save history failed: %{public}d', error.code);
    }
  }

  private decode(text: string): string[] {
    if (text.length === 0) {
      return [];
    }
    try {
      const values: string[] = JSON.parse(text) as string[];
      const result: string[] = [];
      for (let i = 0; i < values.length && result.length < SearchConstants.HISTORY_MAX; i += 1) {
        const item: string = values[i];
        if (typeof item === 'string' && item.trim().length > 0 && result.indexOf(item) < 0) {
          result.push(item);
        }
      }
      return result;
    } catch (err) {
      return [];
    }
  }
}

/** 全局唯一实例。 */
export const searchStore: SearchStore = new SearchStore();
