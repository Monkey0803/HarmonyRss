/*
 * SyncCollector.ets — 领域数据 ↔ 同步记录的双向搬运。
 *
 * 采集（collect）：把当前订阅源与文章状态快照和本地同步表比对，**只把变化的项标脏**。
 * 这样不需要在每个写入口（列表 / 详情 / 多选 / 规则 / 批量）埋点，快照比对能覆盖全部路径；
 * 代价是一次 O(n) 扫描，而同步是手动触发的，可以接受。
 *
 * 应用（apply）：把合并后的订阅源 / 文章状态写回现有存储。
 * 只写「变化了的字段」，不动未纳入同步的字段（etag、抓取统计、正文等）。
 */

import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FeedSource } from '../../model/Feed';
import { Highlight } from '../../model/Highlight';
import { TagWithCount } from '../../model/Tag';
import { BackupArticleTag, BackupHighlight, BackupScalar, BackupSettings, BackupTag } from '../../model/Backup';
import {
  ArticleStatePayload,
  ArticleTagPayload,
  FeedPayload,
  HighlightPayload,
  SyncField,
  SyncKinds,
  SyncKeys,
  SyncRecord,
  TagPayload,
  decodeArticleStatePayload,
  decodeArticleTagPayload,
  decodeFeedPayload,
  decodeHighlightPayload,
  decodeTagPayload,
  encodeArticleStatePayload,
  encodeArticleTagPayload,
  encodeFeedPayload,
  encodeHighlightPayload,
  encodeTagPayload,
  latestFieldAt
} from '../../model/Sync';
import { ArticleDbConstants } from '../../common/constants/RssConstants';
import { articleStore } from '../ArticleStore';
import { feedMergeKey, feedStore } from '../FeedStore';
import { normalizeTagName, tagNameKey, tagStore } from '../TagStore';
import { settingsStore } from '../SettingsStore';
import { isSettingsKeyAllowed, settingsWhitelist } from '../BackupCodec';
import { appSettings } from '../../model/AppSettings';
import { ThemeController } from '../ThemeController';
import { LocaleController } from '../LocaleController';
import { SyncStore } from './SyncStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'SyncCollector';

/** 文章状态的本地快照行（只取同步需要的列）。 */
class ArticleSyncRow {
  readonly id: string;
  readonly read: boolean;
  readonly starred: boolean;
  readonly saved: boolean;
  readonly progressRatio: number;

  constructor(id: string, read: boolean, starred: boolean, saved: boolean, progressRatio: number) {
    this.id = id;
    this.read = read;
    this.starred = starred;
    this.saved = saved;
    this.progressRatio = progressRatio;
  }
}

function flag(value: boolean): string {
  return value ? '1' : '0';
}

/** 订阅源快照是否与同步记录一致（只比同步字段）。 */
export function sameFeed(record: SyncRecord, payload: FeedPayload): boolean {
  const prior: FeedPayload | undefined = decodeFeedPayload(record.payload);
  if (prior === undefined) {
    return false;
  }
  return prior.url === payload.url && prior.title === payload.title &&
    prior.siteUrl === payload.siteUrl && prior.group === payload.group &&
    prior.enabled === payload.enabled;
}

/**
 * 文章状态快照合并：值没变的字段保留原来的时间戳，避免「同步一次把旧值刷新成新时间」。
 * 纯函数，单测直接覆盖（不依赖数据库）。
 */
export function mergeSnapshot(prior: ArticleStatePayload | undefined, read: boolean, starred: boolean,
  saved: boolean, progressRatio: number, now: number): ArticleStatePayload {
  const readField: SyncField = new SyncField(flag(read), now);
  const starredField: SyncField = new SyncField(flag(starred), now);
  const savedField: SyncField = new SyncField(flag(saved), now);
  const progress: SyncField = new SyncField(progressRatio.toString(), now);
  if (prior === undefined) {
    return new ArticleStatePayload(readField, starredField, savedField, progress);
  }
  return new ArticleStatePayload(
    pickField(prior.read, readField),
    pickField(prior.starred, starredField),
    pickField(prior.saved, savedField),
    pickField(prior.progress, progress));
}

function pickField(prior: SyncField, current: SyncField): SyncField {
  return prior.value === current.value ? prior : current;
}

/** 设置载荷解码：只接受白名单键与合法标量，其余静默丢弃。 */
function decodeSettings(text: string): BackupSettings | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const raw: Record<string, BackupScalar> = JSON.parse(text) as Record<string, BackupScalar>;
    const values: Record<string, BackupScalar> = {};
    const keys: string[] = Object.keys(raw);
    for (let i = 0; i < keys.length; i += 1) {
      const key: string = keys[i];
      if (!isSettingsKeyAllowed(key)) {
        continue;
      }
      const value: BackupScalar = raw[key];
      if (typeof value === 'string' || typeof value === 'boolean' ||
        (typeof value === 'number' && Number.isFinite(value))) {
        values[key] = value;
      }
    }
    return new BackupSettings(values);
  } catch (err) {
    return undefined;
  }
}

/** 白名单键逐个比较：任一不同就需要写回。 */
function sameSettings(left: BackupSettings, right: BackupSettings): boolean {
  const keys: string[] = settingsWhitelist();
  for (let i = 0; i < keys.length; i += 1) {
    if (left.get(keys[i]) !== right.get(keys[i])) {
      return false;
    }
  }
  return true;
}

export class SyncCollector {
  private readonly store: SyncStore;
  private readonly origin: string;

  constructor(store: SyncStore, origin: string) {
    this.store = store;
    this.origin = origin;
  }

  /** 采集当前本地状态；返回本次标脏的条数。 */
  async collect(context: common.Context, now: number): Promise<number> {
    let changed: number = 0;
    changed += await this.collectFeeds(context, now);
    changed += await this.collectArticleStates(now);
    changed += await this.collectHighlights(now);
    changed += await this.collectTags(now);
    changed += await this.collectArticleTags(now);
    changed += await this.collectSettings(now);
    return changed;
  }

  private async collectFeeds(context: common.Context, now: number): Promise<number> {
    const feeds: FeedSource[] = await feedStore.load(context, false);
    const existing: SyncRecord[] = await this.store.listByKind(SyncKinds.FEED);
    const known: Map<string, SyncRecord> = new Map<string, SyncRecord>();
    for (let i = 0; i < existing.length; i += 1) {
      known.set(existing[i].key, existing[i]);
    }
    const seen: Set<string> = new Set<string>();
    let changed: number = 0;
    for (let i = 0; i < feeds.length; i += 1) {
      const feed: FeedSource = feeds[i];
      const mergeKey: string = feedMergeKey(feed.url, feed.id);
      if (mergeKey.length === 0) {
        continue;
      }
      const key: string = SyncKeys.feedKey(mergeKey);
      seen.add(key);
      const payload: FeedPayload =
        new FeedPayload(feed.url, feed.title, feed.siteUrl, feed.group, feed.enabled);
      const prior: SyncRecord | undefined = known.get(key);
      if (prior !== undefined && !prior.deleted && sameFeed(prior, payload)) {
        continue;
      }
      this.store.upsert(new SyncRecord(key, SyncKinds.FEED, now, false,
        encodeFeedPayload(payload), this.origin), true);
      changed += 1;
    }
    // 本地删掉的订阅：留墓碑，删除才能传播到另一端。
    for (let i = 0; i < existing.length; i += 1) {
      const prior: SyncRecord = existing[i];
      if (prior.deleted || seen.has(prior.key)) {
        continue;
      }
      this.store.upsert(new SyncRecord(prior.key, SyncKinds.FEED, now, true, '', this.origin), true);
      changed += 1;
    }
    return changed;
  }

  private async collectArticleStates(now: number): Promise<number> {
    const rows: ArticleSyncRow[] = await this.loadArticleRows();
    const existing: SyncRecord[] = await this.store.listByKind(SyncKinds.ARTICLE_STATE);
    const known: Map<string, SyncRecord> = new Map<string, SyncRecord>();
    for (let i = 0; i < existing.length; i += 1) {
      known.set(existing[i].key, existing[i]);
    }
    let changed: number = 0;
    for (let i = 0; i < rows.length; i += 1) {
      const row: ArticleSyncRow = rows[i];
      const key: string = SyncKeys.articleStateKey(row.id);
      const prior: SyncRecord | undefined = known.get(key);
      const priorPayload: ArticleStatePayload | undefined = prior !== undefined && !prior.deleted
        ? decodeArticleStatePayload(prior.payload) : undefined;
      const payload: ArticleStatePayload =
        mergeSnapshot(priorPayload, row.read, row.starred, row.saved, row.progressRatio, now);
      if (priorPayload !== undefined &&
        encodeArticleStatePayload(priorPayload) === encodeArticleStatePayload(payload)) {
        continue;
      }
      this.store.upsert(new SyncRecord(key, SyncKinds.ARTICLE_STATE, latestFieldAt(payload), false,
        encodeArticleStatePayload(payload), this.origin), true);
      changed += 1;
    }
    return changed;
  }

  /**
   * 通用差量采集：把「当前快照（key → payload）」与同步表比对，只把变化的项标脏。
   * @param tombstones 本地已消失的记录是否留墓碑（订阅 / 高亮 / 标签 / 关联要；设置不需要）
   */
  private async collectSnapshots(kind: string, current: Map<string, string>, now: number,
    tombstones: boolean): Promise<number> {
    const existing: SyncRecord[] = await this.store.listByKind(kind);
    const known: Map<string, SyncRecord> = new Map<string, SyncRecord>();
    for (let i = 0; i < existing.length; i += 1) {
      known.set(existing[i].key, existing[i]);
    }
    let changed: number = 0;
    current.forEach((payload: string, key: string) => {
      const prior: SyncRecord | undefined = known.get(key);
      if (prior !== undefined && !prior.deleted && prior.payload === payload) {
        return;
      }
      this.store.upsert(new SyncRecord(key, kind, now, false, payload, this.origin), true);
      changed += 1;
    });
    if (!tombstones) {
      return changed;
    }
    for (let i = 0; i < existing.length; i += 1) {
      const prior: SyncRecord = existing[i];
      if (prior.deleted || current.has(prior.key)) {
        continue;
      }
      this.store.upsert(new SyncRecord(prior.key, kind, now, true, '', this.origin), true);
      changed += 1;
    }
    return changed;
  }

  /** 高亮：改备注 / 改配色 / 删除都会体现在载荷或墓碑上。 */
  private async collectHighlights(now: number): Promise<number> {
    const current: Map<string, string> = new Map<string, string>();
    const rows: Highlight[] = await this.loadHighlights();
    for (let i = 0; i < rows.length; i += 1) {
      const row: Highlight = rows[i];
      const payload: HighlightPayload = new HighlightPayload(row.id, row.articleId, row.quote,
        row.note, row.color, row.createdAt, row.anchorText, row.anchorRatio);
      current.set(SyncKeys.highlightKey(row.id), encodeHighlightPayload(payload));
    }
    return this.collectSnapshots(SyncKinds.HIGHLIGHT, current, now, true);
  }

  /** 标签：键用归一化名称，两端同名标签自然收敛成一条。 */
  private async collectTags(now: number): Promise<number> {
    const current: Map<string, string> = new Map<string, string>();
    const rows: BackupTag[] = await tagStore.allForBackup();
    for (let i = 0; i < rows.length; i += 1) {
      const nameKey: string = tagNameKey(rows[i].name);
      if (nameKey.length === 0) {
        continue;
      }
      const payload: TagPayload = new TagPayload(normalizeTagName(rows[i].name));
      current.set(SyncKeys.tagKey(nameKey), encodeTagPayload(payload));
    }
    return this.collectSnapshots(SyncKinds.TAG, current, now, true);
  }

  /** 文章 ↔ 标签关联：键 = 标签归一化名 + 文章 id。 */
  private async collectArticleTags(now: number): Promise<number> {
    const current: Map<string, string> = new Map<string, string>();
    const tags: BackupTag[] = await tagStore.allForBackup();
    const nameKeyById: Map<string, string> = new Map<string, string>();
    const nameById: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < tags.length; i += 1) {
      const nameKey: string = tagNameKey(tags[i].name);
      if (nameKey.length > 0) {
        nameKeyById.set(tags[i].id, nameKey);
        nameById.set(tags[i].id, normalizeTagName(tags[i].name));
      }
    }
    const links: BackupArticleTag[] = await articleStore.allArticleTagsForBackup();
    for (let i = 0; i < links.length; i += 1) {
      const link: BackupArticleTag = links[i];
      const nameKey: string | undefined = nameKeyById.get(link.tagId);
      const display: string | undefined = nameById.get(link.tagId);
      if (nameKey === undefined || display === undefined) {
        continue;
      }
      const payload: ArticleTagPayload = new ArticleTagPayload(link.articleId, nameKey, display);
      current.set(SyncKeys.articleTagKey(nameKey, link.articleId),
        encodeArticleTagPayload(payload));
    }
    return this.collectSnapshots(SyncKinds.ARTICLE_TAG, current, now, true);
  }

  /** 设置：白名单键的扁平 JSON，单条记录整体后写胜出。 */
  private async collectSettings(now: number): Promise<number> {
    const current: Map<string, string> = new Map<string, string>();
    const settings: BackupSettings = settingsStore.exportWhitelisted();
    current.set(SyncKeys.SETTINGS, JSON.stringify(settings.values));
    return this.collectSnapshots(SyncKinds.SETTINGS, current, now, false);
  }

  /** 全表读高亮（复用备份导出，避免再写一份 SQL）。 */
  private async loadHighlights(): Promise<Highlight[]> {
    const rows: BackupHighlight[] = await articleStore.allHighlightsForBackup();
    const result: Highlight[] = [];
    for (let i = 0; i < rows.length; i += 1) {
      const row: BackupHighlight = rows[i];
      result.push(new Highlight(row.id, row.articleId, row.quote, row.note, row.color,
        row.createdAt, row.anchorText, row.anchorRatio));
    }
    return result;
  }

  /** 全表读文章状态（含重复项：它们的状态同样要同步出去）。 */
  private async loadArticleRows(): Promise<ArticleSyncRow[]> {
    const rows: ArticleSyncRow[] = [];
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined) {
      return rows;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id, is_read, is_starred, is_saved, progress_ratio FROM ' +
        ArticleDbConstants.TABLE_ARTICLES);
      try {
        while (rs.goToNextRow()) {
          const ratio: number = rs.getDouble(rs.getColumnIndex('progress_ratio'));
          rows.push(new ArticleSyncRow(
            rs.getString(rs.getColumnIndex('id')),
            rs.getLong(rs.getColumnIndex('is_read')) === 1,
            rs.getLong(rs.getColumnIndex('is_starred')) === 1,
            rs.getLong(rs.getColumnIndex('is_saved')) === 1,
            Number.isFinite(ratio) ? ratio : 0));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'loadArticleRows failed: %{public}d', error.code);
    }
    return rows;
  }

  /** 把合并后的记录写回订阅源与文章状态；返回实际改动条数。 */
  async apply(context: common.Context): Promise<number> {
    let applied: number = 0;
    applied += await this.applyFeeds(context);
    applied += await this.applyArticleStates();
    applied += await this.applyHighlights();
    applied += await this.applyTags();
    applied += await this.applyArticleTags();
    applied += await this.applySettings(context);
    return applied;
  }

  private async applyFeeds(context: common.Context): Promise<number> {
    const local: FeedSource[] = await feedStore.load(context, false);
    const records: SyncRecord[] = await this.store.listByKind(SyncKinds.FEED);
    if (records.length === 0) {
      return 0;
    }
    const byKey: Map<string, SyncRecord> = new Map<string, SyncRecord>();
    for (let i = 0; i < records.length; i += 1) {
      byKey.set(records[i].key, records[i]);
    }
    const result: FeedSource[] = [];
    let changed: number = 0;
    const kept: Set<string> = new Set<string>();
    for (let i = 0; i < local.length; i += 1) {
      const feed: FeedSource = local[i];
      const mergeKey: string = feedMergeKey(feed.url, feed.id);
      if (mergeKey.length === 0) {
        result.push(feed);
        continue;
      }
      const key: string = SyncKeys.feedKey(mergeKey);
      const record: SyncRecord | undefined = byKey.get(key);
      if (record === undefined) {
        result.push(feed);
        continue;
      }
      kept.add(key);
      if (record.deleted) {
        changed += 1;
        continue;
      }
      const payload: FeedPayload | undefined = decodeFeedPayload(record.payload);
      if (payload === undefined) {
        result.push(feed);
        continue;
      }
      if (feed.title !== payload.title) {
        feed.title = payload.title;
        changed += 1;
      }
      if (feed.siteUrl !== payload.siteUrl) {
        feed.siteUrl = payload.siteUrl;
        changed += 1;
      }
      if (feed.group !== payload.group) {
        feed.group = payload.group;
        changed += 1;
      }
      if (feed.enabled !== payload.enabled) {
        feed.enabled = payload.enabled;
        changed += 1;
      }
      result.push(feed);
    }
    // 远端新增的订阅：本机没有就补进来。
    byKey.forEach((record: SyncRecord, key: string) => {
      if (record.deleted || kept.has(key)) {
        return;
      }
      const payload: FeedPayload | undefined = decodeFeedPayload(record.payload);
      if (payload === undefined) {
        return;
      }
      const feed: FeedSource = new FeedSource(payload.url, payload.title, payload.url,
        payload.siteUrl, payload.group);
      feed.enabled = payload.enabled;
      result.push(feed);
      changed += 1;
    });
    if (changed > 0) {
      feedStore.save(result);
    }
    return changed;
  }

  private async applyArticleStates(): Promise<number> {
    const records: SyncRecord[] = await this.store.listByKind(SyncKinds.ARTICLE_STATE);
    if (records.length === 0) {
      return 0;
    }
    const ids: string[] = [];
    const payloads: ArticleStatePayload[] = [];
    for (let i = 0; i < records.length; i += 1) {
      const record: SyncRecord = records[i];
      if (record.deleted || !record.key.startsWith(SyncKeys.ARTICLE_STATE)) {
        continue;
      }
      const payload: ArticleStatePayload | undefined = decodeArticleStatePayload(record.payload);
      if (payload === undefined) {
        continue;
      }
      ids.push(record.key.substring(SyncKeys.ARTICLE_STATE.length));
      payloads.push(payload);
    }
    if (ids.length === 0) {
      return 0;
    }
    const current: Map<string, ArticleSyncRow> = await this.loadRowsByIds(ids);
    let applied: number = 0;
    for (let i = 0; i < ids.length; i += 1) {
      const row: ArticleSyncRow | undefined = current.get(ids[i]);
      if (row === undefined) {
        // 本机没有这篇文章（未订阅该源 / 已清理）：状态先留着，等文章入库后再合并。
        continue;
      }
      const payload: ArticleStatePayload = payloads[i];
      const read: boolean = payload.read.value === '1';
      const starred: boolean = payload.starred.value === '1';
      const saved: boolean = payload.saved.value === '1';
      // 进度只在记录里保留：写回需要秒数，留给下一批随阅读进度同步一起接。
      if (row.read !== read) {
        articleStore.setRead(ids[i], read);
        applied += 1;
      }
      if (row.starred !== starred) {
        articleStore.setStarred(ids[i], starred);
        applied += 1;
      }
      if (row.saved !== saved) {
        articleStore.setSaved(ids[i], saved);
        applied += 1;
      }
    }
    return applied;
  }

  /** 把合并后的高亮写回本地：文章不存在的先跳过，等文章入库后下次同步再补。 */
  private async applyHighlights(): Promise<number> {
    const records: SyncRecord[] = await this.store.listByKind(SyncKinds.HIGHLIGHT);
    if (records.length === 0) {
      return 0;
    }
    const locals: Highlight[] = await this.loadHighlights();
    const localById: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < locals.length; i += 1) {
      const row: Highlight = locals[i];
      localById.set(row.id, encodeHighlightPayload(new HighlightPayload(row.id, row.articleId,
        row.quote, row.note, row.color, row.createdAt, row.anchorText, row.anchorRatio)));
    }
    const payloads: HighlightPayload[] = [];
    const articleIds: string[] = [];
    let applied: number = 0;
    for (let i = 0; i < records.length; i += 1) {
      const record: SyncRecord = records[i];
      if (!record.key.startsWith(SyncKeys.HIGHLIGHT)) {
        continue;
      }
      const id: string = record.key.substring(SyncKeys.HIGHLIGHT.length);
      if (record.deleted) {
        if (localById.has(id)) {
          articleStore.deleteHighlight(id);
          applied += 1;
        }
        continue;
      }
      const payload: HighlightPayload | undefined = decodeHighlightPayload(record.payload);
      if (payload === undefined) {
        continue;
      }
      payloads.push(payload);
      articleIds.push(payload.articleId);
    }
    const articles: Map<string, ArticleSyncRow> = await this.loadRowsByIds(articleIds);
    for (let i = 0; i < payloads.length; i += 1) {
      const payload: HighlightPayload = payloads[i];
      if (!articles.has(payload.articleId)) {
        continue;
      }
      if (localById.get(payload.id) === encodeHighlightPayload(payload)) {
        continue;
      }
      articleStore.addHighlight(new Highlight(payload.id, payload.articleId, payload.quote,
        payload.note, payload.color, payload.createdAt, payload.anchorText, payload.anchorRatio));
      applied += 1;
    }
    return applied;
  }

  /** 把合并后的标签写回本地：同名标签直接复用，不再新建。 */
  private async applyTags(): Promise<number> {
    const records: SyncRecord[] = await this.store.listByKind(SyncKinds.TAG);
    if (records.length === 0) {
      return 0;
    }
    const locals: BackupTag[] = await tagStore.allForBackup();
    const byKey: Map<string, BackupTag> = new Map<string, BackupTag>();
    for (let i = 0; i < locals.length; i += 1) {
      const nameKey: string = tagNameKey(locals[i].name);
      if (nameKey.length > 0) {
        byKey.set(nameKey, locals[i]);
      }
    }
    let applied: number = 0;
    for (let i = 0; i < records.length; i += 1) {
      const record: SyncRecord = records[i];
      if (!record.key.startsWith(SyncKeys.TAG)) {
        continue;
      }
      const nameKey: string = record.key.substring(SyncKeys.TAG.length);
      if (record.deleted) {
        const existing: BackupTag | undefined = byKey.get(nameKey);
        if (existing !== undefined) {
          await tagStore.remove(existing.id);
          applied += 1;
        }
        continue;
      }
      const payload: TagPayload | undefined = decodeTagPayload(record.payload);
      if (payload === undefined) {
        continue;
      }
      const display: string = normalizeTagName(payload.name);
      const current: BackupTag | undefined = byKey.get(tagNameKey(payload.name));
      if (current !== undefined) {
        // 同名标签已存在：只在展示形式不同时改名（大小写 / 空白差异）。
        if (current.name !== display) {
          const renamed: boolean = await tagStore.rename(current.id, display);
          if (renamed) {
            applied += 1;
          }
        }
        continue;
      }
      const created: TagWithCount | undefined = await tagStore.create(display);
      if (created !== undefined) {
        applied += 1;
      }
    }
    return applied;
  }

  /** 把合并后的文章 ↔ 标签关联写回本地（标签记录尚未落地的先跳过）。 */
  private async applyArticleTags(): Promise<number> {
    const records: SyncRecord[] = await this.store.listByKind(SyncKinds.ARTICLE_TAG);
    if (records.length === 0) {
      return 0;
    }
    const tags: BackupTag[] = await tagStore.allForBackup();
    const idByKey: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < tags.length; i += 1) {
      const nameKey: string = tagNameKey(tags[i].name);
      if (nameKey.length > 0) {
        idByKey.set(nameKey, tags[i].id);
      }
    }
    const articleIds: string[] = [];
    for (let i = 0; i < records.length; i += 1) {
      const record: SyncRecord = records[i];
      if (record.deleted || !record.key.startsWith(SyncKeys.ARTICLE_TAG)) {
        continue;
      }
      const payload: ArticleTagPayload | undefined = decodeArticleTagPayload(record.payload);
      if (payload !== undefined) {
        articleIds.push(payload.articleId);
      }
    }
    const articles: Map<string, ArticleSyncRow> = await this.loadRowsByIds(articleIds);
    let applied: number = 0;
    for (let i = 0; i < records.length; i += 1) {
      const record: SyncRecord = records[i];
      if (!record.key.startsWith(SyncKeys.ARTICLE_TAG)) {
        continue;
      }
      const body: string = record.key.substring(SyncKeys.ARTICLE_TAG.length);
      const split: number = body.indexOf('|');
      if (split <= 0 || split >= body.length - 1) {
        continue;
      }
      const nameKey: string = body.substring(0, split);
      const articleId: string = body.substring(split + 1);
      const tagId: string | undefined = idByKey.get(nameKey);
      if (tagId === undefined) {
        continue;
      }
      if (record.deleted) {
        await tagStore.removeFromArticle(tagId, articleId);
        applied += 1;
        continue;
      }
      if (!articles.has(articleId)) {
        continue;
      }
      applied += await tagStore.addToArticles(tagId, [articleId]);
    }
    return applied;
  }

  /** 设置：只在白名单键真的变化时才写回，避免每次同步都保存一遍偏好。 */
  private async applySettings(context: common.Context): Promise<number> {
    const record: SyncRecord | undefined = await this.store.find(SyncKeys.SETTINGS);
    if (record === undefined || record.deleted) {
      return 0;
    }
    const incoming: BackupSettings | undefined = decodeSettings(record.payload);
    if (incoming === undefined) {
      return 0;
    }
    if (sameSettings(settingsStore.exportWhitelisted(), incoming)) {
      return 0;
    }
    settingsStore.applyWhitelisted(incoming);
    ThemeController.apply(context, appSettings.themeMode);
    LocaleController.apply(appSettings.languageMode);
    return 1;
  }

  private async loadRowsByIds(ids: string[]): Promise<Map<string, ArticleSyncRow>> {
    const result: Map<string, ArticleSyncRow> = new Map<string, ArticleSyncRow>();
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || ids.length === 0) {
      return result;
    }
    const chunk: number = 500;
    for (let start = 0; start < ids.length; start += chunk) {
      const slice: string[] = ids.slice(start, start + chunk);
      const marks: string[] = [];
      for (let i = 0; i < slice.length; i += 1) {
        marks.push('?');
      }
      try {
        const rs: relationalStore.ResultSet = await store.querySql(
          'SELECT id, is_read, is_starred, is_saved, progress_ratio FROM ' +
          ArticleDbConstants.TABLE_ARTICLES + ' WHERE id IN (' + marks.join(',') + ')', slice);
        try {
          while (rs.goToNextRow()) {
            const ratio: number = rs.getDouble(rs.getColumnIndex('progress_ratio'));
            const row: ArticleSyncRow = new ArticleSyncRow(
              rs.getString(rs.getColumnIndex('id')),
              rs.getLong(rs.getColumnIndex('is_read')) === 1,
              rs.getLong(rs.getColumnIndex('is_starred')) === 1,
              rs.getLong(rs.getColumnIndex('is_saved')) === 1,
              Number.isFinite(ratio) ? ratio : 0);
            result.set(row.id, row);
          }
        } finally {
          rs.close();
        }
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'loadRowsByIds failed: %{public}d', error.code);
      }
    }
    return result;
  }
}
