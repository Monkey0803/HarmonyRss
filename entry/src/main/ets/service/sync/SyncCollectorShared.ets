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

export const DOMAIN: number = 0x0000;
export const SYNC_SETTINGS_KEYS: string[] = settingsWhitelist();
export const TAG: string = 'SyncCollector';

/** 内置默认分享模板 id（与 ShareTemplates 内部常量一致；该模板未落库，不参与同步）。 */
export const DEFAULT_TEMPLATE_ID: string = 'tpl_default';

/** 数组排序副本：规则里的引用顺序不影响语义，排序后两端编码一致。 */
export function sortedCopy(values: string[]): string[] {
  const copy: string[] = values.slice();
  copy.sort();
  return copy;
}

/** 两个字符串集合是否相同（忽略顺序）。 */
export function sameStringSet(left: string[], right: string[]): boolean {
  const a: string[] = sortedCopy(left);
  const b: string[] = sortedCopy(right);
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

/** 规则内容是否一致（忽略顺序；命中统计与优先级不参与比较）。 */
export function sameRulePayload(left: RulePayload, right: RulePayload): boolean {
  return left.name.trim() === right.name.trim() && left.enabled === right.enabled &&
    sameStringSet(left.keywords, right.keywords) &&
    sameStringSet(left.fields, right.fields) &&
    sameStringSet(left.actions, right.actions) &&
    sameStringSet(left.feedKeys, right.feedKeys) &&
    sameStringSet(left.tagNames, right.tagNames);
}

/** 文章状态的本地快照行（只取同步需要的列）。 */
export class ArticleSyncRow {
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

export function flag(value: boolean): string {
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

/** 无变化时无需构造新载荷并重复 JSON 序列化。 */
export function sameArticleSnapshot(prior: ArticleStatePayload | undefined, read: boolean, starred: boolean,
  saved: boolean, progressRatio: number): boolean {
  return prior !== undefined && prior.read.value === flag(read) &&
    prior.starred.value === flag(starred) && prior.saved.value === flag(saved) &&
    prior.progress.value === progressRatio.toString();
}

export function pickField(prior: SyncField, current: SyncField): SyncField {
  return prior.value === current.value ? prior : current;
}

/** 设置载荷解码：只接受白名单键与合法标量，其余静默丢弃。 */
export function decodeSettings(text: string): BackupSettings | undefined {
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
export function sameSettings(left: BackupSettings, right: BackupSettings): boolean {
  const keys: string[] = SYNC_SETTINGS_KEYS;
  for (let i = 0; i < keys.length; i += 1) {
    if (left.get(keys[i]) !== right.get(keys[i])) {
      return false;
    }
  }
  return true;
}

/** 本地 feed id → 订阅源归一化键。 */
export async function feedKeyById(context: common.Context): Promise<Map<string, string>> {
  const result: Map<string, string> = new Map<string, string>();
  const feeds: FeedSource[] = await feedStore.load(context, false);
  for (let i = 0; i < feeds.length; i += 1) {
    const key: string = feedMergeKey(feeds[i].url, feeds[i].id);
    if (key.length > 0) {
      result.set(feeds[i].id, key);
    }
  }
  return result;
}

/** 标签 id → 归一化名称。 */
export async function tagNameById(): Promise<Map<string, string>> {
  const result: Map<string, string> = new Map<string, string>();
  const tags: BackupTag[] = await tagStore.allForBackup();
  for (let i = 0; i < tags.length; i += 1) {
    const name: string = normalizeTagName(tags[i].name);
    if (name.length > 0) {
      result.set(tags[i].id, name);
    }
  }
  return result;
}

/**
 * 规则的同步载荷：引用换成稳定标识，数组排序后再编码
 * （顺序不影响语义，排序后两端编码一致，避免无意义的来回覆盖）。
 */
export function rulePayloadOf(rule: Rule, feedKeyById: Map<string, string>,
  tagNameById: Map<string, string>): RulePayload {
  const feedKeys: string[] = [];
  for (let i = 0; i < rule.feedIds.length; i += 1) {
    const key: string | undefined = feedKeyById.get(rule.feedIds[i]);
    if (key !== undefined) {
      feedKeys.push(key);
    }
  }
  const tagNames: string[] = [];
  for (let i = 0; i < rule.tagIds.length; i += 1) {
    const name: string | undefined = tagNameById.get(rule.tagIds[i]);
    if (name !== undefined) {
      tagNames.push(name);
    }
  }
  return new RulePayload(rule.name.trim(), rule.enabled,
    sortedCopy(rule.keywords), sortedCopy(rule.fields), sortedCopy(rule.actions),
    sortedCopy(feedKeys), sortedCopy(tagNames));
}

/** 全表读高亮（复用备份导出，避免再写一份 SQL）。 */
export async function loadHighlights(): Promise<Highlight[]> {
  const rows: BackupHighlight[] = await highlightStore.allHighlightsForBackup();
  const result: Highlight[] = [];
  for (let i = 0; i < rows.length; i += 1) {
    const row: BackupHighlight = rows[i];
    result.push(new Highlight(row.id, row.articleId, row.quote, row.note, row.color,
      row.createdAt, row.anchorText, row.anchorRatio));
  }
  return result;
}
