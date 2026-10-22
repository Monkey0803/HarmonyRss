/*
 * SmartFolderStore.ets — 智能文件夹的本地存储（Model 层）。
 *
 * 智能文件夹只保存「名称 + 检索语法原始串」。打开时把原始串交给现有搜索链路执行，
 * 不新增 DSL、不预先编译 —— 语法演进后旧数据仍然可用。
 *
 * 校验（纯函数，便于单测）：
 *   - 名称非空且 ≤ 32 字符；
 *   - 查询串非空、`emptyQuery()` 判定为非空（纯空白 / 只有 `from:` 之类无效语法 → 拒绝）、≤ 512 字符；
 *   - 数量 ≤ 50。
 */

import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SmartFolder } from '../model/Tag';
import { ArticleDbConstants, TagConstants } from '../common/constants/RssConstants';
import { articleStore } from './ArticleStore';
import { emptyQuery } from './SearchQueryParser';

const DOMAIN: number = 0x0000;
const TAG: string = 'SmartFolderStore';

/** 校验结果码（视图据此提示具体原因）。用字符串常量而非 enum：跨层比较时类型最简单。 */
export class SmartFolderError {
  static readonly NONE: string = 'none';
  /** 名称为空。 */
  static readonly NAME_EMPTY: string = 'nameEmpty';
  /** 名称超长（>32）。 */
  static readonly NAME_TOO_LONG: string = 'nameTooLong';
  /** 查询串为空（空串 / 纯空白 / 仅无效语法）。 */
  static readonly QUERY_EMPTY: string = 'queryEmpty';
  /** 查询串超长（>512）。 */
  static readonly QUERY_TOO_LONG: string = 'queryTooLong';
  /** 数量已达软上限。 */
  static readonly LIMIT_REACHED: string = 'limitReached';
}

/** 名称归一：trim + 连续空白折叠（不截断，超长由校验拒绝，避免静默改用户输入）。 */
export function normalizeFolderName(raw: string): string {
  return raw.replace(/\s+/g, ' ').trim();
}

/**
 * 校验一次创建 / 编辑请求（纯函数，可单测）。
 *
 * @param name          用户输入的名称
 * @param query         用户输入的查询串
 * @param existingCount 当前已存在的智能文件夹数量
 * @param isCreate      true = 新建（检查数量上限）；false = 编辑（不检查上限）
 */
export function validateSmartFolder(name: string, query: string, existingCount: number,
  isCreate: boolean): string {
  const folderName: string = normalizeFolderName(name);
  if (folderName.length === 0) {
    return SmartFolderError.NAME_EMPTY;
  }
  if (folderName.length > TagConstants.TAG_NAME_MAX) {
    return SmartFolderError.NAME_TOO_LONG;
  }
  const rawQuery: string = query.trim();
  if (rawQuery.length === 0 || emptyQuery(rawQuery)) {
    return SmartFolderError.QUERY_EMPTY;
  }
  if (rawQuery.length > TagConstants.SMART_FOLDER_QUERY_MAX) {
    return SmartFolderError.QUERY_TOO_LONG;
  }
  if (isCreate && existingCount >= TagConstants.MAX_SMART_FOLDERS) {
    return SmartFolderError.LIMIT_REACHED;
  }
  return SmartFolderError.NONE;
}

/**
 * 上移 / 下移后的目标下标（纯函数，可单测）：越界时原样返回。
 */
export function movedIndex(index: number, delta: number, length: number): number {
  if (length <= 1) {
    return index;
  }
  const target: number = index + delta;
  if (index < 0 || index >= length || target < 0 || target >= length) {
    return index;
  }
  return target;
}

/** 生成稳定 id：时间戳 + 随机后缀。 */
function newId(): string {
  return 'sf_' + Date.now() + '_' + Math.floor(Math.random() * 1000000);
}

export class SmartFolderStore {
  /** 全部智能文件夹（按 sort_order 升序）。库不可用时返回空数组。 */
  async list(): Promise<SmartFolder[]> {
    // 冷启动时订阅页可能早于 open() 完成就读取计数：先等库就绪，避免首屏显示 0。
    await articleStore.whenReady();
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    const result: SmartFolder[] = [];
    if (store === undefined) {
      return result;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id, name, query, sort_order, created_at, updated_at FROM ' +
        ArticleDbConstants.TABLE_SMART_FOLDERS + ' ORDER BY sort_order ASC, created_at ASC');
      try {
        while (rs.goToNextRow()) {
          result.push(this.fromRow(rs));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'list failed: %{public}d', error.code);
    }
    return result;
  }

  /**
   * 新建：校验通过后追加到末尾（sort_order = 当前最大值 + 1）。
   * 失败返回 undefined（调用方用 validate 的结果提示原因）。
   */
  async create(name: string, query: string): Promise<SmartFolder | undefined> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined) {
      return undefined;
    }
    const existing: SmartFolder[] = await this.list();
    if (validateSmartFolder(name, query, existing.length, true) !== SmartFolderError.NONE) {
      return undefined;
    }
    let nextOrder: number = 0;
    for (let i = 0; i < existing.length; i += 1) {
      nextOrder = Math.max(nextOrder, existing[i].sortOrder + 1);
    }
    const id: string = newId();
    const now: number = Date.now();
    const displayName: string = normalizeFolderName(name);
    const rawQuery: string = query.trim();
    try {
      store.executeSync('INSERT INTO ' + ArticleDbConstants.TABLE_SMART_FOLDERS +
        ' (id, name, query, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        [id, displayName, rawQuery, nextOrder, now, now]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'create failed: %{public}d', error.code);
      return undefined;
    }
    return new SmartFolder(id, displayName, rawQuery, nextOrder, now, now);
  }

  /** 编辑名称 / 查询串（校验同创建，但不检查数量上限）。 */
  async update(id: string, name: string, query: string): Promise<boolean> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || id.length === 0) {
      return false;
    }
    if (validateSmartFolder(name, query, 0, false) !== SmartFolderError.NONE) {
      return false;
    }
    try {
      store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_SMART_FOLDERS +
        ' SET name = ?, query = ?, updated_at = ? WHERE id = ?',
        [normalizeFolderName(name), query.trim(), Date.now(), id]);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'update failed: %{public}d', error.code);
      return false;
    }
  }

  /** 删除智能文件夹（只删保存的查询，文章不受影响）。 */
  async remove(id: string): Promise<void> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || id.length === 0) {
      return;
    }
    try {
      store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_SMART_FOLDERS + ' WHERE id = ?', [id]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'remove failed: %{public}d', error.code);
    }
  }

  /**
   * 上移（delta = -1）/ 下移（delta = 1）：与相邻项交换位置。
   * 交换后统一写回连续的 sort_order（0..n-1），避免历史数据里出现重复排序位。
   */
  async move(id: string, delta: number): Promise<void> {
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined || id.length === 0 || delta === 0) {
      return;
    }
    const items: SmartFolder[] = await this.list();
    let index: number = -1;
    for (let i = 0; i < items.length; i += 1) {
      if (items[i].id === id) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      return;
    }
    const target: number = movedIndex(index, delta, items.length);
    if (target === index) {
      return;
    }
    const reordered: SmartFolder[] = items.slice();
    const moved: SmartFolder = reordered[index];
    reordered[index] = reordered[target];
    reordered[target] = moved;
    try {
      store.beginTransaction();
      try {
        for (let i = 0; i < reordered.length; i += 1) {
          store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_SMART_FOLDERS +
            ' SET sort_order = ? WHERE id = ?', [i, reordered[i].id]);
        }
        store.commit();
      } catch (inner) {
        store.rollBack();
        throw inner as Error;
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'move failed: %{public}d', error.code);
    }
  }

  private fromRow(rs: relationalStore.ResultSet): SmartFolder {
    return new SmartFolder(
      rs.getString(rs.getColumnIndex('id')),
      rs.getString(rs.getColumnIndex('name')),
      rs.getString(rs.getColumnIndex('query')),
      rs.getLong(rs.getColumnIndex('sort_order')),
      rs.getLong(rs.getColumnIndex('created_at')),
      rs.getLong(rs.getColumnIndex('updated_at')));
  }
}

/** 全局唯一实例。 */
export const smartFolderStore: SmartFolderStore = new SmartFolderStore();
