/*
 * TranslationStore.ets — 翻译结果缓存（独立 RDB，按文章 + 目标语言）。
 *
 * 为什么单独一个库：翻译缓存是纯可再生成数据，和主库（订阅 / 文章 / 标注）解耦，
 * 清理 / 重建时不会碰到主库；主库也不用为它加版本迁移。
 *
 * 缓存键 = (article_id, target_lang)：同一篇文章切换目标语言会各存一份；
 * 源语言 / 服务 / 段落 JSON / 更新时间随行保存。超过保留天数或条数上限时自动清理最旧的。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TranslateLimits } from '../common/constants/TranslateConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'TranslationStore';
const DB_NAME: string = 'harmony_rss_translations.db';
const TABLE: string = 'translations';
const DAY_MS: number = 24 * 60 * 60 * 1000;

const SQL_CREATE: string =
  'CREATE TABLE IF NOT EXISTS ' + TABLE + ' (' +
  'article_id TEXT NOT NULL, ' +
  'target_lang TEXT NOT NULL, ' +
  'source_lang TEXT NOT NULL DEFAULT \'\', ' +
  'provider TEXT NOT NULL DEFAULT \'\', ' +
  'payload TEXT NOT NULL DEFAULT \'\', ' +
  'updated_at INTEGER NOT NULL DEFAULT 0, ' +
  'PRIMARY KEY (article_id, target_lang))';

/** 一条缓存记录。 */
export class TranslationCacheRow {
  readonly articleId: string;
  readonly sourceLang: string;
  readonly targetLang: string;
  readonly provider: string;
  readonly payload: string;
  readonly updatedAt: number;

  constructor(articleId: string, sourceLang: string, targetLang: string, provider: string,
    payload: string, updatedAt: number) {
    this.articleId = articleId;
    this.sourceLang = sourceLang;
    this.targetLang = targetLang;
    this.provider = provider;
    this.payload = payload;
    this.updatedAt = updatedAt;
  }
}

export class TranslationStore {
  private store: relationalStore.RdbStore | undefined = undefined;
  private opened: boolean = false;

  /** 打开缓存库（幂等）。失败时翻译仍可用，只是不缓存。 */
  async open(context: common.Context): Promise<void> {
    if (this.opened) {
      return;
    }
    this.opened = true;
    try {
      const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      this.store = await relationalStore.getRdbStore(context, config);
      this.store.executeSync(SQL_CREATE);
      this.prune();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'open failed, cache disabled: %{public}d', error.code);
      this.store = undefined;
    }
  }

  /** 清理过期与超额缓存（打开时执行一次）。 */
  private prune(): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      const cutoff: number = Date.now() - TranslateLimits.CACHE_DAYS * DAY_MS;
      store.executeSync('DELETE FROM ' + TABLE + ' WHERE updated_at < ?', [cutoff]);
      store.executeSync('DELETE FROM ' + TABLE + ' WHERE rowid NOT IN (' +
        'SELECT rowid FROM ' + TABLE + ' ORDER BY updated_at DESC LIMIT ?)',
        [TranslateLimits.MAX_CACHE_ENTRIES]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'prune failed: %{public}d', error.code);
    }
  }

  /** 读缓存；没有 / 解析失败返回 undefined。 */
  async get(articleId: string, targetLang: string): Promise<TranslationCacheRow | undefined> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || articleId.length === 0 || targetLang.length === 0) {
      return undefined;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT article_id, source_lang, target_lang, provider, payload, updated_at FROM ' + TABLE +
        ' WHERE article_id = ? AND target_lang = ?', [articleId, targetLang]);
      try {
        if (!rs.goToNextRow()) {
          return undefined;
        }
        return new TranslationCacheRow(
          rs.getString(rs.getColumnIndex('article_id')),
          rs.getString(rs.getColumnIndex('source_lang')),
          rs.getString(rs.getColumnIndex('target_lang')),
          rs.getString(rs.getColumnIndex('provider')),
          rs.getString(rs.getColumnIndex('payload')),
          rs.getLong(rs.getColumnIndex('updated_at')));
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'get failed: %{public}d', error.code);
      return undefined;
    }
  }

  /** 写缓存（同文章 + 目标语言覆盖旧值）。 */
  put(articleId: string, sourceLang: string, targetLang: string, provider: string,
    payload: string): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || articleId.length === 0 || targetLang.length === 0 || payload.length === 0) {
      return;
    }
    try {
      store.executeSync('INSERT OR REPLACE INTO ' + TABLE +
        ' (article_id, target_lang, source_lang, provider, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        [articleId, targetLang, sourceLang, provider, payload, Date.now()]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'put failed: %{public}d', error.code);
    }
  }

  /** 缓存条数（设置页展示 / 清理确认）。 */
  async count(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet =
        await store.querySql('SELECT COUNT(*) AS c FROM ' + TABLE);
      try {
        if (!rs.goToNextRow()) {
          return 0;
        }
        return rs.getLong(rs.getColumnIndex('c'));
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'count failed: %{public}d', error.code);
      return 0;
    }
  }

  /** 清空全部翻译缓存；返回清理条数。 */
  async clear(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    const before: number = await this.count();
    try {
      store.executeSync('DELETE FROM ' + TABLE);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'clear failed: %{public}d', error.code);
      return 0;
    }
    return before;
  }
}

/** 全局唯一实例。 */
export const translationStore: TranslationStore = new TranslationStore();
