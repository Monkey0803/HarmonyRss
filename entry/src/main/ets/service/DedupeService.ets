/*
 * DedupeService.ets — 跨源去重的匹配决策与「组操作」统一入口。
 *
 * 分工：
 *   1) 纯决策（static，可单测）：findMatches / resolveRoot / pickPromotion —— 只在内存里算，
 *      不碰数据库，方便在入库前批量定好 canonical_id；
 *   2) 组操作（async）：groupIds / expandIds / applyRead / applyStarred / applyHidden / applyTag ——
 *      把「一篇」的操作扩散到「整组」（主条 + 全部重复项），保证 UI、规则、远端三条路径行为一致。
 *
 * 约定：
 *   - 只做「挂靠关系」与状态同步，绝不修改 / 删除文章内容（FR-014）；
 *   - 所有异常只记日志并返回空结果 / 默认值，调用方按「降级为独立文章」处理（FR-011）；
 *   - 不依赖 FeedViewModel / RemoteSyncService，避免循环依赖（它们反过来依赖本服务）。
 */

import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DedupeCandidate } from '../model/Dedupe';
import { articleStore } from './ArticleStore';
import { tagStore } from './TagStore';
import { sameTitleWindow } from './DedupeKeys';

const DOMAIN: number = 0x0000;
const TAG: string = 'DedupeService';

/** 表名 / 列名（列名与 ArticleDbConstants 的 v7 迁移保持一致）。 */
const TABLE_ARTICLES: string = 'articles';
const COL_ID: string = 'id';
const COL_CANONICAL: string = 'canonical_id';
const COL_IS_READ: string = 'is_read';
const COL_IS_STARRED: string = 'is_starred';
const COL_IS_HIDDEN: string = 'is_hidden';

/** 解析根主条的最大跳数（防御脏数据造成的环）。 */
const MAX_ROOT_DEPTH: number = 32;

/** 生成 n 个逗号分隔的占位符（IN (?,?,…) 用）。 */
function placeholders(count: number): string {
  const parts: string[] = [];
  for (let i = 0; i < count; i += 1) {
    parts.push('?');
  }
  return parts.join(',');
}

/** 把候选挂到索引桶里（键为空表示不参与该维度匹配）。 */
function indexCandidate(index: Map<string, DedupeCandidate[]>, key: string,
  candidate: DedupeCandidate): void {
  if (key.length === 0) {
    return;
  }
  const bucket: DedupeCandidate[] | undefined = index.get(key);
  if (bucket === undefined) {
    index.set(key, [candidate]);
    return;
  }
  bucket.push(candidate);
}

export class DedupeService {
  /**
   * 批量匹配：入参是「库里已有的候选」与「本批要入库的候选」，返回 incoming.id → 主条 id。
   *
   * 规则：
   *   - 只在 feedId 不同时生效（同源重复交给既有 id 去重）；
   *   - URL 键优先，未命中再看标题键 + ±24h 时间窗；
   *   - 命中的若是重复项，沿 canonicalId 解析到根主条（先入库者为永久主条）；
   *   - 同一条 incoming 只匹配一次；本批中先出现的 incoming 也会成为后续 incoming 的候选，
   *     避免「同一批里两个源收录同一篇」各自独立。
   */
  static findMatches(existing: DedupeCandidate[], incoming: DedupeCandidate[]): Map<string, string> {
    const matches: Map<string, string> = new Map<string, string>();
    const byId: Map<string, DedupeCandidate> = new Map<string, DedupeCandidate>();
    const byLink: Map<string, DedupeCandidate[]> = new Map<string, DedupeCandidate[]>();
    const byTitle: Map<string, DedupeCandidate[]> = new Map<string, DedupeCandidate[]>();
    for (let i = 0; i < existing.length; i += 1) {
      const item: DedupeCandidate = existing[i];
      if (item.id.length === 0) {
        continue;
      }
      byId.set(item.id, item);
      indexCandidate(byLink, item.linkKey, item);
      indexCandidate(byTitle, item.titleKey, item);
    }
    for (let i = 0; i < incoming.length; i += 1) {
      const item: DedupeCandidate = incoming[i];
      if (item.id.length === 0) {
        continue;
      }
      let root: string = '';
      if (item.linkKey.length > 0) {
        root = DedupeService.matchByLink(byLink, item, byId);
      }
      if (root.length === 0 && item.titleKey.length > 0) {
        root = DedupeService.matchByTitle(byTitle, item, byId);
      }
      // 本批后续 incoming 需要看到「这篇已经挂到谁名下」，因此把结果登记进索引。
      const registered: DedupeCandidate = root.length > 0
        ? new DedupeCandidate(item.id, item.feedId, root, item.linkKey, item.titleKey, item.publishedAt)
        : item;
      byId.set(item.id, registered);
      indexCandidate(byLink, item.linkKey, registered);
      indexCandidate(byTitle, item.titleKey, registered);
      if (root.length > 0) {
        matches.set(item.id, root);
      }
    }
    return matches;
  }

  /** 沿 canonicalId 解析到根主条；自身就是主条 / 不存在 / 成环时返回能到达的最后一跳。 */
  static resolveRoot(id: string, byId: Map<string, DedupeCandidate>): string {
    if (id.length === 0) {
      return '';
    }
    let current: string = id;
    for (let depth = 0; depth < MAX_ROOT_DEPTH; depth += 1) {
      const candidate: DedupeCandidate | undefined = byId.get(current);
      if (candidate === undefined) {
        return current;
      }
      const next: string = candidate.canonicalId;
      if (next.length === 0 || next === current) {
        return current;
      }
      current = next;
    }
    return current;
  }

  /**
   * 主条提升决策：在剩余成员里选「最早入库 / 发布时间最小」的一条（先入库者优先）。
   * 发布时间为 0（未知）视为最晚，保证有明确时间的文章优先；全部未知时取第一个。
   * 空数组返回空串。
   */
  static pickPromotion(candidates: DedupeCandidate[]): string {
    let bestId: string = '';
    let bestAt: number = 0;
    for (let i = 0; i < candidates.length; i += 1) {
      const item: DedupeCandidate = candidates[i];
      if (item.id.length === 0) {
        continue;
      }
      const at: number = item.publishedAt > 0 ? item.publishedAt : Number.MAX_SAFE_INTEGER;
      if (bestId.length === 0 || at < bestAt) {
        bestId = item.id;
        bestAt = at;
      }
    }
    return bestId;
  }

  /**
   * 组内全部 id：主条自身 + canonical_id 指向它的重复项。
   * 传入的若是重复项，先解析到根再展开；库不可用 / 查不到时退回 [articleId]（幂等，不报错）。
   */
  async groupIds(articleId: string): Promise<string[]> {
    const result: string[] = [];
    if (articleId.length === 0) {
      return result;
    }
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined) {
      result.push(articleId);
      return result;
    }
    try {
      const root: string = await this.rootOf(store, articleId);
      const seen: Set<string> = new Set<string>();
      const args: Array<relationalStore.ValueType> = [root, root];
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT ' + COL_ID + ' FROM ' + TABLE_ARTICLES +
        ' WHERE ' + COL_ID + ' = ? OR ' + COL_CANONICAL + ' = ?', args);
      try {
        while (rs.goToNextRow()) {
          const id: string = rs.getString(rs.getColumnIndex(COL_ID));
          if (id.length > 0 && !seen.has(id)) {
            seen.add(id);
            result.push(id);
          }
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: Error = err as Error;
      hilog.error(DOMAIN, TAG, 'groupIds failed: %{public}s', error.message);
      return [articleId];
    }
    if (result.length === 0) {
      result.push(articleId);
    }
    return result;
  }

  /** 批量展开为组 id（保序去重）：多选 / 规则命中一次传入多篇时用。 */
  async expandIds(ids: string[]): Promise<string[]> {
    const result: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < ids.length; i += 1) {
      const group: string[] = await this.groupIds(ids[i]);
      for (let j = 0; j < group.length; j += 1) {
        const id: string = group[j];
        if (id.length > 0 && !seen.has(id)) {
          seen.add(id);
          result.push(id);
        }
      }
    }
    return result;
  }

  /** 已读：展开到整组后批量落库；返回实际更新的条数（失败返回 0）。 */
  async applyRead(ids: string[], value: boolean): Promise<number> {
    return await this.applyFlag(COL_IS_READ, ids, value);
  }

  /** 收藏：展开到整组后批量落库。 */
  async applyStarred(ids: string[], value: boolean): Promise<number> {
    return await this.applyFlag(COL_IS_STARRED, ids, value);
  }

  /** 隐藏：展开到整组后批量落库（主条隐藏 → 整组不进主列表）。 */
  async applyHidden(ids: string[], value: boolean): Promise<number> {
    return await this.applyFlag(COL_IS_HIDDEN, ids, value);
  }

  /** 打标签：展开到整组后逐个 INSERT OR IGNORE；返回新增的关联条数。 */
  async applyTag(tagId: string, ids: string[]): Promise<number> {
    if (tagId.length === 0 || ids.length === 0) {
      return 0;
    }
    try {
      const expanded: string[] = await this.expandIds(ids);
      if (expanded.length === 0) {
        return 0;
      }
      return await tagStore.addToArticles(tagId, expanded);
    } catch (err) {
      const error: Error = err as Error;
      hilog.error(DOMAIN, TAG, 'applyTag failed: %{public}s', error.message);
      return 0;
    }
  }

  /** 解析某篇的根主条 id（查不到 / 值为空时视为自身）。 */
  private async rootOf(store: relationalStore.RdbStore, articleId: string): Promise<string> {
    const args: Array<relationalStore.ValueType> = [articleId];
    const rs: relationalStore.ResultSet = await store.querySql(
      'SELECT ' + COL_CANONICAL + ' FROM ' + TABLE_ARTICLES + ' WHERE ' + COL_ID + ' = ?', args);
    try {
      if (!rs.goToNextRow()) {
        return articleId;
      }
      const canonical: string = rs.getString(rs.getColumnIndex(COL_CANONICAL));
      return canonical.length > 0 ? canonical : articleId;
    } finally {
      rs.close();
    }
  }

  /** 组内批量改一个布尔列（列名只来自本文件的常量，参数一律走绑定）。 */
  private async applyFlag(column: string, ids: string[], value: boolean): Promise<number> {
    if (ids.length === 0) {
      return 0;
    }
    try {
      const expanded: string[] = await this.expandIds(ids);
      if (expanded.length === 0) {
        return 0;
      }
      const store: relationalStore.RdbStore | undefined = articleStore.getStore();
      if (store === undefined) {
        return 0;
      }
      const args: Array<relationalStore.ValueType> = [value ? 1 : 0];
      for (let i = 0; i < expanded.length; i += 1) {
        args.push(expanded[i]);
      }
      store.executeSync('UPDATE ' + TABLE_ARTICLES + ' SET ' + column +
        ' = ? WHERE ' + COL_ID + ' IN (' + placeholders(expanded.length) + ')', args);
      return expanded.length;
    } catch (err) {
      const error: Error = err as Error;
      hilog.error(DOMAIN, TAG, 'applyFlag(' + column + ') failed: %{public}s', error.message);
      return 0;
    }
  }

  /** 按 URL 键找根主条；跳过自己与同源候选。 */
  private static matchByLink(index: Map<string, DedupeCandidate[]>, item: DedupeCandidate,
    byId: Map<string, DedupeCandidate>): string {
    const bucket: DedupeCandidate[] | undefined = index.get(item.linkKey);
    if (bucket === undefined) {
      return '';
    }
    for (let i = 0; i < bucket.length; i += 1) {
      const hit: DedupeCandidate = bucket[i];
      if (hit.id === item.id || hit.feedId === item.feedId) {
        continue;
      }
      const root: string = DedupeService.resolveRoot(hit.id, byId);
      if (DedupeService.isUsableRoot(root, item, byId)) {
        return root;
      }
    }
    return '';
  }

  /** 按标题键 + ±24h 时间窗找根主条；跳过自己与同源候选。 */
  private static matchByTitle(index: Map<string, DedupeCandidate[]>, item: DedupeCandidate,
    byId: Map<string, DedupeCandidate>): string {
    const bucket: DedupeCandidate[] | undefined = index.get(item.titleKey);
    if (bucket === undefined) {
      return '';
    }
    for (let i = 0; i < bucket.length; i += 1) {
      const hit: DedupeCandidate = bucket[i];
      if (hit.id === item.id || hit.feedId === item.feedId) {
        continue;
      }
      if (!sameTitleWindow(hit.publishedAt, item.publishedAt)) {
        continue;
      }
      const root: string = DedupeService.resolveRoot(hit.id, byId);
      if (DedupeService.isUsableRoot(root, item, byId)) {
        return root;
      }
    }
    return '';
  }

  /**
   * 根主条是否可用：不能是自己，也不能与本条同源。
   * 后者保证「同一源内的文章」不会被别的源的重复项桥接进同一组（FR-010：同源重复交给既有 id 去重）。
   */
  private static isUsableRoot(root: string, item: DedupeCandidate,
    byId: Map<string, DedupeCandidate>): boolean {
    if (root.length === 0 || root === item.id) {
      return false;
    }
    const rootCandidate: DedupeCandidate | undefined = byId.get(root);
    if (rootCandidate === undefined) {
      return true;
    }
    return rootCandidate.feedId !== item.feedId;
  }
}

/** 单例：组操作统一从这里进（纯决策也可用 DedupeService.xxx 静态调用）。 */
export const dedupeService: DedupeService = new DedupeService();

/** 函数式入口：批量匹配（incoming.id → 主条 id）。 */
export function findMatches(existing: DedupeCandidate[], incoming: DedupeCandidate[]): Map<string, string> {
  return DedupeService.findMatches(existing, incoming);
}

/** 函数式入口：解析根主条。 */
export function resolveRoot(id: string, byId: Map<string, DedupeCandidate>): string {
  return DedupeService.resolveRoot(id, byId);
}

/** 函数式入口：主条提升选择。 */
export function pickPromotion(candidates: DedupeCandidate[]): string {
  return DedupeService.pickPromotion(candidates);
}
