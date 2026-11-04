/* Site-specific web-mode memory with TTL and legacy-format migration. */
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';

/** 只能靠 JS 渲染的站点上限：只保留最近记录的这些，避免偏好库无限增长。 */
const MAX_READER_WEB_SITES: number = 300;

/**
 * 站点记忆的有效期：超时后重新尝试静态正文提取。
 * 一次偶发失败（超时 / 断网）不应该让某个站点永久停在加载更慢的网页原文。
 */
const READER_WEB_SITE_TTL_MS: number = 7 * 24 * 60 * 60 * 1000;

/** 偏好库里的站点记忆条目（host + 记录时间）。旧版本只有 host 字符串。 */
interface ReaderWebSiteMemoRaw {
  host: string;
  at: number;
}

export class ReaderSitePreferenceStore {
  private store: preferences.Preferences | undefined = undefined;
  private readerWebSites: Map<string, number> = new Map<string, number>();

  load(store: preferences.Preferences, raw: string): void {
    this.store = store;
    this.readerWebSites.clear();
    const siteMemos: ReaderWebSiteMemoRaw[] = this.readReaderWebSiteMemos(raw);
    const now: number = Date.now();
    for (let i = 0; i < siteMemos.length; i += 1) {
      const host: string = siteMemos[i].host.trim().toLowerCase();
      const recordedAt: number = siteMemos[i].at;
      if (recordedAt <= 0 || now - recordedAt > READER_WEB_SITE_TTL_MS) {
        continue;
      }
      if (host.length > 0 && host.indexOf(' ') < 0 && host.indexOf('/') < 0) {
        this.readerWebSites.set(host, recordedAt);
      }
    }
  }

  private readReaderWebSiteMemos(raw: string): ReaderWebSiteMemoRaw[] {
    const result: ReaderWebSiteMemoRaw[] = [];
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) {
        return result;
      }
      const values: Object[] = parsed as Object[];
      for (let i = 0; i < values.length && result.length < MAX_READER_WEB_SITES; i += 1) {
        const item: Object = values[i];
        if (typeof item === 'string') {
          result.push({ host: item as string, at: 0 });
          continue;
        }
        const memo: ReaderWebSiteMemoRaw = item as ReaderWebSiteMemoRaw;
        const host: string = typeof memo.host === 'string' ? memo.host : '';
        const at: number = typeof memo.at === 'number' && Number.isFinite(memo.at) ? memo.at : 0;
        if (host.length > 0) {
          result.push({ host: host, at: at });
        }
      }
    } catch (err) {
      return result;
    }
    return result;
  }

  isReaderSiteWebPreferred(host: string): boolean {
    const key: string = host.trim().toLowerCase();
    if (key.length === 0) {
      return false;
    }
    const recordedAt: number | undefined = this.readerWebSites.get(key);
    if (recordedAt === undefined) {
      return false;
    }
    return Date.now() - recordedAt <= READER_WEB_SITE_TTL_MS;
  }

  rememberReaderSiteWeb(host: string): void {
    const key: string = host.trim().toLowerCase();
    if (key.length === 0) {
      return;
    }
    const now: number = Date.now();
    const recordedAt: number | undefined = this.readerWebSites.get(key);
    if (recordedAt !== undefined && now - recordedAt <= READER_WEB_SITE_TTL_MS) {
      return;
    }
    if (this.readerWebSites.size >= MAX_READER_WEB_SITES) {
      this.readerWebSites.clear();
    }
    this.readerWebSites.set(key, now);
    this.persistReaderWebSites();
  }

  preferReaderSite(host: string): void {
    const key: string = host.trim().toLowerCase();
    if (key.length === 0 || !this.readerWebSites.has(key)) {
      return;
    }
    this.readerWebSites.delete(key);
    this.persistReaderWebSites();
  }

  private persistReaderWebSites(): void {
    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return;
    }
    const list: ReaderWebSiteMemoRaw[] = [];
    this.readerWebSites.forEach((recordedAt: number, host: string) => {
      list.push({ host: host, at: recordedAt });
    });
    try {
      store.putSync(PreferencesConstants.KEY_READER_SITE_MODES, JSON.stringify(list));
      store.flush().catch((err: BusinessError) => {
        console.error('SettingsStore.flush failed: ' + err.code.toString());
      });
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('SettingsStore.readerSiteModes failed: ' + error.code.toString());
    }
  }
}
