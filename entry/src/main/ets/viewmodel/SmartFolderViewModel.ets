/*
 * SmartFolderViewModel.ets — 智能文件夹列表与 CRUD 编排（@ObservedV2）。
 *
 * 打开一个智能文件夹不做任何检索：把查询串写进 SearchViewModel.pendingQuery 后跳搜索页，
 * 由搜索页用**同一条**检索链路（FTS / 中文二元组索引 / 分页 / 高亮）执行，保证结果一致。
 */

import { SmartFolder } from '../model/Tag';
import { smartFolderStore, SmartFolderError, validateSmartFolder } from '../service/SmartFolderStore';
import { TagConstants } from '../common/constants/RssConstants';
import { searchViewModel } from './SearchViewModel';

@ObservedV2
export class SmartFolderViewModel {
  /** 全部智能文件夹（按手动排序位）。 */
  @Trace folders: SmartFolder[] = [];
  @Trace loading: boolean = false;
  @Trace failed: boolean = false;
  /** 正在编辑的文件夹 id（空串 = 不在编辑态）。 */
  @Trace editing: string = '';
  /** 最近一次校验失败的原因（视图据此提示；成功时回到 NONE）。 */
  @Trace lastError: string = SmartFolderError.NONE;
  /** 变更版本号（订阅页入口计数读它建立刷新依赖）。 */
  @Trace revision: number = 0;

  /** 读取列表。 */
  async load(): Promise<void> {
    this.loading = true;
    this.failed = false;
    try {
      this.folders = await smartFolderStore.list();
      this.revision += 1;
    } catch (err) {
      this.failed = true;
    } finally {
      this.loading = false;
    }
  }

  /** 数量（订阅页入口计数）。 */
  count(): number {
    return this.folders.length;
  }

  /** 新建：先校验（返回具体原因），通过后落库并刷新。 */
  async create(name: string, query: string): Promise<SmartFolder | undefined> {
    // 从搜索页保存时本页可能还没 load 过：先读一次，数量上限判断才准确。
    if (this.folders.length === 0) {
      await this.load();
    }
    const error: string = validateSmartFolder(name, query, this.folders.length, true);
    this.lastError = error;
    if (error !== SmartFolderError.NONE) {
      return undefined;
    }
    const created: SmartFolder | undefined = await smartFolderStore.create(name, query);
    if (created !== undefined) {
      this.lastError = SmartFolderError.NONE;
      await this.load();
    }
    return created;
  }

  /** 编辑：名称 + 查询串。 */
  async update(id: string, name: string, query: string): Promise<boolean> {
    const error: string = validateSmartFolder(name, query, this.folders.length, false);
    this.lastError = error;
    if (error !== SmartFolderError.NONE) {
      return false;
    }
    const ok: boolean = await smartFolderStore.update(id, name, query);
    if (ok) {
      this.lastError = SmartFolderError.NONE;
      this.editing = '';
      await this.load();
    }
    return ok;
  }

  /** 删除。 */
  async remove(id: string): Promise<void> {
    await smartFolderStore.remove(id);
    if (this.editing === id) {
      this.editing = '';
    }
    await this.load();
  }

  /** 上移 / 下移（delta = -1 / 1）。 */
  async move(id: string, delta: number): Promise<void> {
    await smartFolderStore.move(id, delta);
    await this.load();
  }

  /**
   * 打开：把查询串交给搜索页（pendingQuery）后由视图 push PAGE_SEARCH。
   * 返回 false 表示这条记录已失效（查询为空等），视图给提示。
   */
  open(folder: SmartFolder): boolean {
    const query: string = folder.query.trim();
    if (validateSmartFolder(folder.name, query, this.folders.length, false) !== SmartFolderError.NONE) {
      return false;
    }
    searchViewModel.pendingQuery = query;
    return true;
  }

  /** 当前列表是否还能创建（入口 / 提示用）。 */
  canCreate(): boolean {
    return this.folders.length < TagConstants.MAX_SMART_FOLDERS;
  }
}

/** 全局唯一实例。 */
export const smartFolderViewModel: SmartFolderViewModel = new SmartFolderViewModel();
