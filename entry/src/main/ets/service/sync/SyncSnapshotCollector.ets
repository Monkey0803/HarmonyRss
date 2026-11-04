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

export class SyncSnapshotCollector {
  private readonly store: SyncStore;
  private readonly origin: string;

  constructor(store: SyncStore, origin: string) {
    this.store = store;
    this.origin = origin;
  }

  /** 采集当前本地状态；返回本次标脏的条数。 */
  async collect(context: common.Context, now: number): Promise<number> {
    // 冷启动时 autoSync 可能早于文章库打开：此时文章 / 高亮 / 标签 / 网页的快照全是空的，
    // 继续比对会把「本机还没读到」误判成删除，给对端发墓碑并删掉对方的真实数据。
    if (articleDatabase.getStore() === undefined) {
      hilog.info(DOMAIN, TAG, 'collect skipped: article store not ready');
      return 0;
    }
    let changed: number = 0;
    changed += await this.collectFeeds(context, now);
    changed += await this.collectWebPages(now);
    changed += await this.collectArticleStates(now);
    changed += await this.collectHighlights(now);
    changed += await this.collectTags(now);
    changed += await this.collectArticleTags(now);
    changed += await this.collectSettings(now);
    changed += await this.collectSmartFolders(now);
    changed += await this.collectRules(context, now);
    changed += await this.collectTemplates(context, now);
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

  /**
   * 采集本机保存的独立网页（只同步元数据）。
   * 正文由各端按需重新提取，所以这里绝不把 reader_html 放进 payload。
   */
  private async collectWebPages(now: number): Promise<number> {
    const pages: WebPagePayload[] = await articleRepository.listSavedWebPages();
    const existing: SyncRecord[] = await this.store.listByKind(SyncKinds.WEB_PAGE);
    const known: Map<string, SyncRecord> = new Map<string, SyncRecord>();
    for (let i = 0; i < existing.length; i += 1) {
      known.set(existing[i].key, existing[i]);
    }
    const seen: Set<string> = new Set<string>();
    let changed: number = 0;
    for (let i = 0; i < pages.length; i += 1) {
      const page: WebPagePayload = pages[i];
      const urlKey: string = DedupeKeys.urlKey(page.url);
      if (urlKey.length === 0) {
        continue;
      }
      const key: string = SyncKeys.webPageKey(urlKey);
      seen.add(key);
      const payload: string = encodeWebPagePayload(page);
      const prior: SyncRecord | undefined = known.get(key);
      if (prior !== undefined && !prior.deleted && prior.payload === payload) {
        continue;
      }
      this.store.upsert(new SyncRecord(key, SyncKinds.WEB_PAGE, now, false, payload, this.origin), true);
      changed += 1;
    }
    // 本地删掉的网页：留墓碑，删除才会传播到另一端。
    for (let i = 0; i < existing.length; i += 1) {
      const prior: SyncRecord = existing[i];
      if (prior.deleted || seen.has(prior.key)) {
        continue;
      }
      this.store.upsert(new SyncRecord(prior.key, SyncKinds.WEB_PAGE, now, true, '', this.origin), true);
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
      if (sameArticleSnapshot(priorPayload, row.read, row.starred, row.saved, row.progressRatio)) {
        continue;
      }
      const payload: ArticleStatePayload =
        mergeSnapshot(priorPayload, row.read, row.starred, row.saved, row.progressRatio, now);
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
    const rows: Highlight[] = await loadHighlights();
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
    const links: BackupArticleTag[] = await tagStore.allArticleTagsForBackup();
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

  /** 智能文件夹：名称 + 检索语法（排序位是设备本地偏好，不同步）。 */
  private async collectSmartFolders(now: number): Promise<number> {
    const current: Map<string, string> = new Map<string, string>();
    const rows: SmartFolder[] = await smartFolderStore.list();
    for (let i = 0; i < rows.length; i += 1) {
      const row: SmartFolder = rows[i];
      const nameKey: string = SyncKeys.nameKey(row.name);
      if (nameKey.length === 0) {
        continue;
      }
      const payload: SmartFolderPayload = new SmartFolderPayload(row.name.trim(), row.query);
      current.set(SyncKeys.smartFolderKey(nameKey), encodeSmartFolderPayload(payload));
    }
    return this.collectSnapshots(SyncKinds.SMART_FOLDER, current, now, true);
  }

  /** 规则：订阅源 / 标签引用换成稳定标识（归一化 URL / 归一化名称）。 */
  private async collectRules(context: common.Context, now: number): Promise<number> {
    const current: Map<string, string> = new Map<string, string>();
    const feedKeyById: Map<string, string> = await loadFeedKeys(context);
    const tagNameById: Map<string, string> = await loadTagNames();
    const rows: Rule[] = await ruleStore.list();
    for (let i = 0; i < rows.length; i += 1) {
      const rule: Rule = rows[i];
      const nameKey: string = SyncKeys.nameKey(rule.name);
      if (nameKey.length === 0) {
        continue;
      }
      const payload: RulePayload = rulePayloadOf(rule, feedKeyById, tagNameById);
      current.set(SyncKeys.ruleKey(nameKey), encodeRulePayload(payload));
    }
    return this.collectSnapshots(SyncKinds.RULE, current, now, true);
  }

  /** 分享模板：名称 + 正文（排序位不同步）；内置默认模板未落库，不参与同步。 */
  private async collectTemplates(context: common.Context, now: number): Promise<number> {
    await shareTemplates.open(context);
    const current: Map<string, string> = new Map<string, string>();
    const items: ShareTemplate[] = await shareTemplates.list();
    for (let i = 0; i < items.length; i += 1) {
      const item: ShareTemplate = items[i];
      // 内置默认模板只在内存里存在，同步它会让对端凭空多出一个模板。
      if (item.id === DEFAULT_TEMPLATE_ID) {
        continue;
      }
      const nameKey: string = SyncKeys.nameKey(item.name);
      if (nameKey.length === 0) {
        continue;
      }
      const payload: TemplatePayload = new TemplatePayload(item.name.trim(), item.content);
      current.set(SyncKeys.templateKey(nameKey), encodeTemplatePayload(payload));
    }
    return this.collectSnapshots(SyncKinds.TEMPLATE, current, now, true);
  }

  /** 全表读文章状态（含重复项：它们的状态同样要同步出去）。 */
  private async loadArticleRows(): Promise<ArticleSyncRow[]> {
    const rows: ArticleSyncRow[] = [];
    const store: relationalStore.RdbStore | undefined = articleDatabase.getStore();
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

}
