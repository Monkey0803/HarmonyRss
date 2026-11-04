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
import { SmartFolder, TagWithCount } from '../../model/Tag';
import { Rule, RuleDraft } from '../../model/Rule';
import { ShareTemplate } from '../../model/Share';
import { BackupArticleTag, BackupHighlight, BackupScalar, BackupSettings, BackupTag } from '../../model/Backup';
import {
  ArticleStatePayload,
  ArticleTagPayload,
  FeedPayload,
  HighlightPayload,
  RulePayload,
  SmartFolderPayload,
  SyncField,
  SyncKinds,
  SyncKeys,
  SyncRecord,
  TagPayload,
  TemplatePayload,
  WebPagePayload,
  decodeArticleStatePayload,
  decodeArticleTagPayload,
  decodeFeedPayload,
  decodeHighlightPayload,
  decodeRulePayload,
  decodeSmartFolderPayload,
  decodeTagPayload,
  decodeTemplatePayload,
  decodeWebPagePayload,
  encodeArticleStatePayload,
  encodeArticleTagPayload,
  encodeFeedPayload,
  encodeHighlightPayload,
  encodeRulePayload,
  encodeSmartFolderPayload,
  encodeTagPayload,
  encodeTemplatePayload,
  encodeWebPagePayload,
  latestFieldAt
} from '../../model/Sync';
import { ArticleDbConstants } from '../../common/constants/RssConstants';
import { highlightStore, articleDatabase, articleRepository } from '../ArticleServices';
import { feedMergeKey, feedStore } from '../FeedStore';
import { normalizeTagName, tagNameKey, tagStore } from '../TagStore';
import { smartFolderStore } from '../SmartFolderStore';
import { ruleStore } from '../RuleStore';
import { shareTemplates } from '../ShareTemplates';
import { settingsStore } from '../SettingsStore';
import { isSettingsKeyAllowed, settingsWhitelist } from '../BackupCodec';
import { appSettings } from '../../model/AppSettings';
import { ThemeController } from '../ThemeController';
import { LocaleController } from '../LocaleController';
import { SyncStore } from './SyncStore';
import { DedupeKeys } from '../DedupeKeys';

import { DOMAIN, SYNC_SETTINGS_KEYS, TAG, DEFAULT_TEMPLATE_ID, sortedCopy, sameStringSet, sameRulePayload, ArticleSyncRow, flag, sameFeed, mergeSnapshot, sameArticleSnapshot, pickField, decodeSettings, sameSettings, feedKeyById as loadFeedKeys, tagNameById as loadTagNames, rulePayloadOf, loadHighlights } from './SyncCollectorShared';

export class SyncSnapshotApplier {
  private readonly store: SyncStore;
  private readonly origin: string;

  constructor(store: SyncStore, origin: string) {
    this.store = store;
    this.origin = origin;
  }

  /** 把合并后的记录写回订阅源与文章状态；返回实际改动条数。 */
  async apply(context: common.Context): Promise<number> {
    let applied: number = 0;
    applied += await this.applyFeeds(context);
    applied += await this.applyWebPages();
    applied += await this.applyArticleStates();
    applied += await this.applyHighlights();
    applied += await this.applyTags();
    applied += await this.applyArticleTags();
    applied += await this.applySettings(context);
    applied += await this.applySmartFolders();
    applied += await this.applyRules(context);
    applied += await this.applyTemplates(context);
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

  /**
   * 回写保存网页：远端新增的补进本机稍后读；远端墓碑删掉本机对应条目。
   * 已存在的条目一律不动，避免覆盖本地已读 / 进度 / 已缓存正文。
   */
  private async applyWebPages(): Promise<number> {
    const records: SyncRecord[] = await this.store.listByKind(SyncKinds.WEB_PAGE);
    if (records.length === 0) {
      return 0;
    }
    const local: WebPagePayload[] = await articleRepository.listSavedWebPages();
    const localKeys: Set<string> = new Set<string>();
    for (let i = 0; i < local.length; i += 1) {
      localKeys.add(DedupeKeys.urlKey(local[i].url));
    }
    let applied: number = 0;
    for (let i = 0; i < records.length; i += 1) {
      const record: SyncRecord = records[i];
      if (!record.key.startsWith(SyncKeys.WEB_PAGE)) {
        continue;
      }
      const urlKey: string = record.key.substring(SyncKeys.WEB_PAGE.length);
      if (urlKey.length === 0) {
        continue;
      }
      if (record.deleted) {
        if (articleRepository.deleteSyncedWebPage(urlKey)) {
          applied += 1;
        }
        continue;
      }
      if (localKeys.has(urlKey)) {
        continue;
      }
      const payload: WebPagePayload | undefined = decodeWebPagePayload(record.payload);
      if (payload === undefined) {
        continue;
      }
      if (articleRepository.insertSyncedWebPage(urlKey, payload)) {
        applied += 1;
      }
    }
    return applied;
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
        articleRepository.setRead(ids[i], read);
        applied += 1;
      }
      if (row.starred !== starred) {
        articleRepository.setStarred(ids[i], starred);
        applied += 1;
      }
      if (row.saved !== saved) {
        articleRepository.setSaved(ids[i], saved);
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
    const locals: Highlight[] = await loadHighlights();
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
          highlightStore.deleteHighlight(id);
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
      highlightStore.addHighlight(new Highlight(payload.id, payload.articleId, payload.quote,
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

  /** 智能文件夹：同名复用，查询串不同则更新；墓碑删除。 */
  private async applySmartFolders(): Promise<number> {
    const records: SyncRecord[] = await this.store.listByKind(SyncKinds.SMART_FOLDER);
    if (records.length === 0) {
      return 0;
    }
    const locals: SmartFolder[] = await smartFolderStore.list();
    const byKey: Map<string, SmartFolder> = new Map<string, SmartFolder>();
    for (let i = 0; i < locals.length; i += 1) {
      byKey.set(SyncKeys.nameKey(locals[i].name), locals[i]);
    }
    let applied: number = 0;
    for (let i = 0; i < records.length; i += 1) {
      const record: SyncRecord = records[i];
      if (!record.key.startsWith(SyncKeys.SMART_FOLDER)) {
        continue;
      }
      const nameKey: string = record.key.substring(SyncKeys.SMART_FOLDER.length);
      const existing: SmartFolder | undefined = byKey.get(nameKey);
      if (record.deleted) {
        if (existing !== undefined) {
          await smartFolderStore.remove(existing.id);
          applied += 1;
        }
        continue;
      }
      const payload: SmartFolderPayload | undefined = decodeSmartFolderPayload(record.payload);
      if (payload === undefined) {
        continue;
      }
      const display: string = payload.name.trim();
      if (existing === undefined) {
        const created: SmartFolder | undefined =
          await smartFolderStore.create(payload.name, payload.query);
        if (created !== undefined) {
          applied += 1;
        }
        continue;
      }
      if (existing.query !== payload.query || existing.name !== display) {
        const updated: boolean = await smartFolderStore.update(existing.id, payload.name, payload.query);
        if (updated) {
          applied += 1;
        }
      }
    }
    return applied;
  }

  /** 规则：引用按稳定标识解析回本地 id；内容一致就不重写。 */
  private async applyRules(context: common.Context): Promise<number> {
    const records: SyncRecord[] = await this.store.listByKind(SyncKinds.RULE);
    if (records.length === 0) {
      return 0;
    }
    const feeds: FeedSource[] = await feedStore.load(context, false);
    const idByFeedKey: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < feeds.length; i += 1) {
      const key: string = feedMergeKey(feeds[i].url, feeds[i].id);
      if (key.length > 0) {
        idByFeedKey.set(key, feeds[i].id);
      }
    }
    const tags: BackupTag[] = await tagStore.allForBackup();
    const idByTagName: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < tags.length; i += 1) {
      const nameKey: string = tagNameKey(tags[i].name);
      if (nameKey.length > 0) {
        idByTagName.set(nameKey, tags[i].id);
      }
    }
    const feedKeyById: Map<string, string> = await loadFeedKeys(context);
    const tagNameById: Map<string, string> = await loadTagNames();
    const locals: Rule[] = await ruleStore.list();
    const byKey: Map<string, Rule> = new Map<string, Rule>();
    for (let i = 0; i < locals.length; i += 1) {
      byKey.set(SyncKeys.nameKey(locals[i].name), locals[i]);
    }
    let applied: number = 0;
    for (let i = 0; i < records.length; i += 1) {
      const record: SyncRecord = records[i];
      if (!record.key.startsWith(SyncKeys.RULE)) {
        continue;
      }
      const nameKey: string = record.key.substring(SyncKeys.RULE.length);
      const existing: Rule | undefined = byKey.get(nameKey);
      if (record.deleted) {
        if (existing !== undefined) {
          await ruleStore.remove(existing.id);
          applied += 1;
        }
        continue;
      }
      const payload: RulePayload | undefined = decodeRulePayload(record.payload);
      if (payload === undefined) {
        continue;
      }
      if (existing !== undefined) {
        const localPayload: RulePayload = rulePayloadOf(existing, feedKeyById, tagNameById);
        if (!sameRulePayload(localPayload, payload)) {
          const updated: boolean =
            await ruleStore.update(existing.id, this.ruleDraftOf(payload, idByFeedKey, idByTagName));
          if (updated) {
            applied += 1;
          }
        }
        continue;
      }
      const created: Rule | undefined =
        await ruleStore.create(this.ruleDraftOf(payload, idByFeedKey, idByTagName));
      if (created !== undefined) {
        applied += 1;
      }
    }
    return applied;
  }

  /** 规则载荷 → 草稿：引用反查本地 id，找不到的引用直接丢弃。 */
  private ruleDraftOf(payload: RulePayload, idByFeedKey: Map<string, string>,
    idByTagName: Map<string, string>): RuleDraft {
    const feedIds: string[] = [];
    for (let i = 0; i < payload.feedKeys.length; i += 1) {
      const id: string | undefined = idByFeedKey.get(payload.feedKeys[i]);
      if (id !== undefined) {
        feedIds.push(id);
      }
    }
    const tagIds: string[] = [];
    for (let i = 0; i < payload.tagNames.length; i += 1) {
      const id: string | undefined = idByTagName.get(tagNameKey(payload.tagNames[i]));
      if (id !== undefined) {
        tagIds.push(id);
      }
    }
    return new RuleDraft(payload.name.trim(), payload.enabled, payload.keywords.slice(),
      payload.fields.slice(), feedIds, payload.actions.slice(), tagIds);
  }

  /** 分享模板：同名复用，正文不同则更新；墓碑删除。 */
  private async applyTemplates(context: common.Context): Promise<number> {
    const records: SyncRecord[] = await this.store.listByKind(SyncKinds.TEMPLATE);
    if (records.length === 0) {
      return 0;
    }
    await shareTemplates.open(context);
    const locals: ShareTemplate[] = await shareTemplates.list();
    const byKey: Map<string, ShareTemplate> = new Map<string, ShareTemplate>();
    for (let i = 0; i < locals.length; i += 1) {
      const item: ShareTemplate = locals[i];
      if (item.id === DEFAULT_TEMPLATE_ID) {
        continue;
      }
      byKey.set(SyncKeys.nameKey(item.name), item);
    }
    let applied: number = 0;
    for (let i = 0; i < records.length; i += 1) {
      const record: SyncRecord = records[i];
      if (!record.key.startsWith(SyncKeys.TEMPLATE)) {
        continue;
      }
      const nameKey: string = record.key.substring(SyncKeys.TEMPLATE.length);
      const existing: ShareTemplate | undefined = byKey.get(nameKey);
      if (record.deleted) {
        if (existing !== undefined) {
          const removed: boolean = await shareTemplates.remove(existing.id);
          if (removed) {
            applied += 1;
          }
        }
        continue;
      }
      const payload: TemplatePayload | undefined = decodeTemplatePayload(record.payload);
      if (payload === undefined) {
        continue;
      }
      const display: string = payload.name.trim();
      if (existing === undefined) {
        const created: ShareTemplate | undefined =
          await shareTemplates.create(payload.name, payload.content);
        if (created !== undefined) {
          applied += 1;
        }
        continue;
      }
      if (existing.content !== payload.content || existing.name !== display) {
        const updated: boolean = await shareTemplates.update(existing.id, payload.name, payload.content);
        if (updated) {
          applied += 1;
        }
      }
    }
    return applied;
  }

  private async loadRowsByIds(ids: string[]): Promise<Map<string, ArticleSyncRow>> {
    const result: Map<string, ArticleSyncRow> = new Map<string, ArticleSyncRow>();
    const store: relationalStore.RdbStore | undefined = articleDatabase.getStore();
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
