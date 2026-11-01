/* 本项目维护的在线精选目录；网络与缓存失败均回退内置目录。 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { DiscoverCategory, DiscoverFeed } from '../model/Discover';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';
import { HttpOptions, httpClient } from './HttpClient';
import { DiscoverService, normalizeFeedKey } from './DiscoverService';

const CATALOG_URL: string =
  'https://raw.githubusercontent.com/Monkey0803/HarmonyRss/main/catalog/feeds.json';
const TTL_MS: number = 24 * 60 * 60 * 1000;
const MAX_CHARS: number = 400000;

interface CatalogRecord {
  title: string;
  feedUrl: string;
  siteUrl: string;
  category: string;
  tags: string[];
  popularity: number;
}

interface CatalogDocument {
  version: number;
  feeds: CatalogRecord[];
}

/** 不接受部分损坏的目录，以免一次更新悄悄清空或替换大批精选源。 */
export function decodeCatalog(text: string): DiscoverFeed[] {
  if (text.length === 0 || text.length > MAX_CHARS) {
    return [];
  }
  try {
    const doc: CatalogDocument = JSON.parse(text) as CatalogDocument;
    if (doc.version !== 1 || !Array.isArray(doc.feeds) || doc.feeds.length < 30 || doc.feeds.length > 1000) {
      return [];
    }
    const seen: Set<string> = new Set<string>();
    const result: DiscoverFeed[] = [];
    for (let i = 0; i < doc.feeds.length; i += 1) {
      const item: CatalogRecord = doc.feeds[i];
      if (typeof item.title !== 'string' || item.title.length === 0 || item.title.length > 100 ||
        typeof item.feedUrl !== 'string' || !item.feedUrl.startsWith('https://') ||
        typeof item.siteUrl !== 'string' || !item.siteUrl.startsWith('https://') ||
        typeof item.category !== 'string' || DiscoverCategory.TOPICS.indexOf(item.category) < 0 ||
        !Array.isArray(item.tags) || item.tags.length > 12 ||
        !item.tags.every((tag: string) => typeof tag === 'string' && tag.length > 0 && tag.length <= 30) ||
        typeof item.popularity !== 'number' || item.popularity < 0 || item.popularity > 100) {
        return [];
      }
      const key: string = normalizeFeedKey(item.feedUrl);
      if (key.length === 0 || seen.has(key)) {
        return [];
      }
      seen.add(key);
      result.push(new DiscoverFeed(item.title, item.feedUrl, item.siteUrl, item.category,
        item.tags, item.popularity));
    }
    return result;
  } catch (err) {
    return [];
  }
}

@ObservedV2
export class DiscoverCatalogService {
  @Trace updatedAt: number = 0;
  @Trace revision: number = 0;
  private store: preferences.Preferences | undefined = undefined;
  private refreshing: boolean = false;

  async open(context: common.Context): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      const cached: string = this.store.getSync(PreferencesConstants.KEY_DISCOVER_CATALOG, '') as string;
      const feeds: DiscoverFeed[] = decodeCatalog(cached);
      if (feeds.length > 0) {
        DiscoverService.setCatalog(feeds);
        this.revision++;
        this.updatedAt = this.store.getSync(PreferencesConstants.KEY_DISCOVER_CATALOG_AT, 0) as number;
      }
    } catch (err) {
      // 内置目录始终可用。
    }
    await this.refresh();
  }

  async refresh(force: boolean = false): Promise<void> {
    if (this.refreshing || (!force && this.updatedAt > 0 && Date.now() - this.updatedAt < TTL_MS)) {
      return;
    }
    this.refreshing = true;
    try {
      const options: HttpOptions = new HttpOptions();
      options.readTimeoutMs = 8000;
      const response = await httpClient.getText(CATALOG_URL, options);
      if (response.status !== 200) {
        return;
      }
      const feeds: DiscoverFeed[] = decodeCatalog(response.text);
      if (feeds.length === 0) {
        return;
      }
      DiscoverService.setCatalog(feeds);
      this.updatedAt = Date.now();
      this.revision++;
      if (this.store !== undefined) {
        this.store.putSync(PreferencesConstants.KEY_DISCOVER_CATALOG, response.text);
        this.store.putSync(PreferencesConstants.KEY_DISCOVER_CATALOG_AT, this.updatedAt);
        await this.store.flush();
      }
    } catch (err) {
      // 保留上次缓存或内置目录。
    } finally {
      this.refreshing = false;
    }
  }
}

export const discoverCatalogService: DiscoverCatalogService = new DiscoverCatalogService();
