/*
 * TagViewModel.ets — 标签页 / 标签选择器 / 详情页 chips 共用的状态与编排（@ObservedV2）。
 *
 * 视图只读状态、上报事件；SQL 与归一 / 去重 / 上限全部在 TagStore。
 * 每次写操作后都刷新列表与计数，保证「打标 → 计数 +1」这类联动立即生效。
 */

import { Article } from '../model/Feed';
import { TagWithCount } from '../model/Tag';
import { tagStore } from '../service/TagStore';
import { TagConstants } from '../common/constants/RssConstants';

@ObservedV2
export class TagViewModel {
  /** 全部标签（含文章计数），按名称排序。 */
  @Trace tags: TagWithCount[] = [];
  /** 标签页里被勾选的标签 id（多选 AND）。 */
  @Trace selectedTagIds: string[] = [];
  /** 进入标签文章页时锁定的标签（标题展示 + 记住筛选条件）。 */
  @Trace activeTags: TagWithCount[] = [];
  /** 标签文章列表（轻量列，分页追加）。 */
  @Trace tagArticles: Article[] = [];
  /** 标签文章总数。 */
  @Trace totalArticles: number = 0;
  /** 是否还有下一页。 */
  @Trace hasMore: boolean = false;
  /** 加载中。 */
  @Trace loading: boolean = false;
  /** 读写失败（库不可用）。 */
  @Trace failed: boolean = false;
  /** 变更版本号：订阅页入口计数等只关心「有没有变」的地方读它建立刷新依赖。 */
  @Trace revision: number = 0;

  private offset: number = 0;
  /** 标签文章查询代次：丢弃过期请求的结果。 */
  private generation: number = 0;

  /** 读取标签列表与计数。 */
  async load(): Promise<void> {
    this.loading = true;
    this.failed = false;
    try {
      this.tags = await tagStore.listTags();
      // 选中态里已被删除的标签顺手剔除，避免「查看结果」带一个不存在的 tag_id。
      this.selectedTagIds = this.selectedTagIds.filter((id: string) => this.hasTag(id));
      this.revision += 1;
    } catch (err) {
      this.failed = true;
    } finally {
      this.loading = false;
    }
  }

  /** 标签总数（订阅页入口计数）。 */
  count(): number {
    return this.tags.length;
  }

  /** 是否有该标签。 */
  hasTag(id: string): boolean {
    for (let i = 0; i < this.tags.length; i += 1) {
      if (this.tags[i].id === id) {
        return true;
      }
    }
    return false;
  }

  /** 按 id 找标签（选中态 / chips 展示用）。 */
  tagById(id: string): TagWithCount | undefined {
    for (let i = 0; i < this.tags.length; i += 1) {
      if (this.tags[i].id === id) {
        return this.tags[i];
      }
    }
    return undefined;
  }

  /** 标签页多选：切换一个标签的选中态。 */
  toggleSelect(id: string): void {
    if (this.selectedTagIds.indexOf(id) >= 0) {
      this.selectedTagIds = this.selectedTagIds.filter((item: string) => item !== id);
    } else {
      this.selectedTagIds = this.selectedTagIds.concat([id]);
    }
  }

  /** 清空多选。 */
  clearSelection(): void {
    this.selectedTagIds = [];
  }

  /** 新建标签（已存在则复用）；返回标签本身，空名 / 超上限返回 undefined。 */
  async create(name: string): Promise<TagWithCount | undefined> {
    const created: TagWithCount | undefined = await tagStore.create(name);
    if (created !== undefined) {
      await this.load();
    }
    return created;
  }

  /** 重命名：成功返回 true（重名 / 空名返回 false）。 */
  async rename(id: string, name: string): Promise<boolean> {
    const ok: boolean = await tagStore.rename(id, name);
    if (ok) {
      await this.load();
    }
    return ok;
  }

  /** 删除标签（文章保留）。 */
  async remove(id: string): Promise<void> {
    await tagStore.remove(id);
    await this.load();
  }

  /** 批量打标：返回新增关联数（重复添加不计）。 */
  async addTagsToArticles(ids: string[], tagId: string): Promise<number> {
    const added: number = await tagStore.addToArticles(tagId, ids);
    await this.load();
    return added;
  }

  /** 单篇移除一个标签。 */
  async removeTagFromArticle(tagId: string, articleId: string): Promise<void> {
    await tagStore.removeFromArticle(tagId, articleId);
    await this.load();
  }

  /** 一篇文章的标签（详情页 chips）。 */
  async tagsOf(articleId: string): Promise<TagWithCount[]> {
    return await tagStore.tagsOfArticle(articleId);
  }

  /**
   * 进入标签文章页：锁定 activeTags，并按多标签 AND 拉第一页。
   * 顺序按传入的 tagIds 在 tags 里的顺序展示（与用户勾选顺序无关，保持一致）。
   */
  async loadArticles(tagIds: string[]): Promise<void> {
    const locked: TagWithCount[] = [];
    for (let i = 0; i < this.tags.length; i += 1) {
      if (tagIds.indexOf(this.tags[i].id) >= 0) {
        locked.push(this.tags[i]);
      }
    }
    // 还没 load 过 / 标签刚创建时，兜底从 Store 再读一次名称。
    if (locked.length !== tagIds.length && tagIds.length > 0) {
      const fresh: TagWithCount[] = await tagStore.listTags();
      for (let i = 0; i < fresh.length; i += 1) {
        if (tagIds.indexOf(fresh[i].id) >= 0 && !this.containsTag(locked, fresh[i].id)) {
          locked.push(fresh[i]);
        }
      }
    }
    this.activeTags = locked;
    this.generation += 1;
    const generation: number = this.generation;
    this.offset = 0;
    this.tagArticles = [];
    this.totalArticles = 0;
    this.hasMore = false;
    if (tagIds.length === 0) {
      return;
    }
    this.loading = true;
    this.failed = false;
    try {
      const page: Article[] = await tagStore.articlesByTags(tagIds, 0, TagConstants.ARTICLES_PAGE_SIZE);
      const total: number = await tagStore.countByTags(tagIds);
      if (generation !== this.generation) {
        return;
      }
      this.tagArticles = page;
      this.totalArticles = total;
      this.offset = page.length;
      this.hasMore = page.length < total;
    } catch (err) {
      if (generation === this.generation) {
        this.failed = true;
      }
    } finally {
      if (generation === this.generation) {
        this.loading = false;
      }
    }
  }

  /** 触底续页。 */
  async loadMoreArticles(): Promise<void> {
    if (this.loading || !this.hasMore || this.activeTags.length === 0) {
      return;
    }
    const tagIds: string[] = this.activeTags.map((item: TagWithCount) => item.id);
    this.generation += 1;
    const generation: number = this.generation;
    this.loading = true;
    try {
      const page: Article[] = await tagStore.articlesByTags(tagIds, this.offset,
        TagConstants.ARTICLES_PAGE_SIZE);
      if (generation !== this.generation) {
        return;
      }
      this.tagArticles = this.tagArticles.concat(page);
      this.offset = this.tagArticles.length;
      this.hasMore = this.tagArticles.length < this.totalArticles;
    } catch (err) {
      if (generation === this.generation) {
        this.failed = true;
      }
    } finally {
      if (generation === this.generation) {
        this.loading = false;
      }
    }
  }

  /** 刷新当前标签文章列表（详情页改标签后返回时用）。 */
  async refreshArticles(): Promise<void> {
    if (this.activeTags.length === 0) {
      return;
    }
    await this.loadArticles(this.activeTags.map((item: TagWithCount) => item.id));
  }

  private containsTag(list: TagWithCount[], id: string): boolean {
    for (let i = 0; i < list.length; i += 1) {
      if (list[i].id === id) {
        return true;
      }
    }
    return false;
  }
}

/** 全局唯一实例。 */
export const tagViewModel: TagViewModel = new TagViewModel();
