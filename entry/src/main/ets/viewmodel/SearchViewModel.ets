/*
 * SearchViewModel.ets — 全局检索页的状态与编排（@ObservedV2）。
 *
 * 查询解析交给 SearchQueryParser（纯函数），检索走 SearchStore（FTS 优先、LIKE 降级）。
 * 视图只读状态、上报输入；这里负责分页、历史、错误态与「打开命中」。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SearchHit, SearchPage, SearchQuery, SearchState } from '../model/Search';
import { searchStore } from '../service/SearchStore';
import { emptyQuery, parse } from '../service/SearchQueryParser';
import { SearchConstants } from '../common/constants/RssConstants';
import { feedViewModel } from './FeedViewModel';

@ObservedV2
export class SearchViewModel {
  /** 输入框里的原始文本。 */
  @Trace raw: string = '';
  /** 状态筛选（chips）：all / unread / starred / saved。 */
  @Trace activeState: string = SearchState.ALL;
  /** 当前结果。 */
  @Trace hits: SearchHit[] = [];
  /** 命中总数。 */
  @Trace total: number = 0;
  /** 是否还有下一页。 */
  @Trace hasMore: boolean = false;
  /** 检索进行中。 */
  @Trace searching: boolean = false;
  /** 检索失败（库异常）。 */
  @Trace failed: boolean = false;
  /** 最近搜索历史。 */
  @Trace history: string[] = [];
  /** 片段高亮用的关键词（短语优先，否则第一个词）。 */
  @Trace currentTerm: string = '';
  /** 是否已执行过检索（用于空态文案区分「未搜索」与「无结果」）。 */
  @Trace searched: boolean = false;
  /** 检索索引是否可用（false = LIKE 降级，功能仍可用）。 */
  @Trace indexed: boolean = true;

  private offset: number = 0;
  /** 查询代次：丢弃过期请求的结果（快速连续输入时）。 */
  private generation: number = 0;
  private opened: boolean = false;

  /** 进入检索页：打开偏好库并读历史。 */
  async init(context: common.Context): Promise<void> {
    if (!this.opened) {
      await searchStore.open(context);
      this.opened = true;
    }
    this.history = searchStore.history();
    // 主索引与中文索引任一可用即走索引；都不可用才是真正的全表 LIKE 降级。
    this.indexed = searchStore.isIndexAvailable();
  }

  /** 提交一次检索（回车 / 点历史 / 点搜索）。 */
  async submit(raw: string): Promise<void> {
    this.searched = raw.trim().length > 0;
    await this.run(raw, true);
  }

  /** 切换状态筛选（chips）：用同一份输入重新检索。 */
  async setState(state: string): Promise<void> {
    if (this.activeState === state) {
      return;
    }
    this.activeState = state;
    if (this.raw.trim().length > 0) {
      await this.run(this.raw, true);
    }
  }

  /** 触底续页。 */
  async loadMore(): Promise<void> {
    if (this.searching || !this.hasMore) {
      return;
    }
    await this.run(this.raw, false);
  }

  /** 清空结果（输入被清空时）。 */
  clearResults(): void {
    this.generation += 1;
    this.hits = [];
    this.total = 0;
    this.hasMore = false;
    this.offset = 0;
    this.searched = false;
    this.failed = false;
    this.searching = false;
  }

  /** 清空搜索历史。 */
  clearHistory(): void {
    searchStore.clearHistory();
    this.history = [];
  }

  /** 打开一条命中：补全正文并定位首个命中；成功返回 true（视图据此 push 详情页）。 */
  async openHit(hit: SearchHit): Promise<boolean> {
    const term: string = this.currentTerm;
    return await feedViewModel.openSearchHit(hit.articleId, term);
  }

  /** 是否展示「空输入」引导。 */
  showHint(): boolean {
    return this.raw.trim().length === 0 && !this.searching;
  }

  /** 是否展示「无结果」。 */
  showEmpty(): boolean {
    return this.searched && !this.searching && !this.failed && this.hits.length === 0;
  }

  private async run(raw: string, reset: boolean): Promise<void> {
    const text: string = raw.trim();
    this.raw = raw;
    if (emptyQuery(text)) {
      this.clearResults();
      return;
    }
    const query: SearchQuery = parse(text);
    if (this.activeState !== SearchState.ALL) {
      query.state = this.activeState;
    }
    this.currentTerm = query.phrase.length > 0
      ? query.phrase
      : (query.terms.length > 0 ? query.terms[0] : query.from);
    if (reset) {
      this.offset = 0;
      this.hits = [];
      this.total = 0;
      this.hasMore = false;
    }
    this.searching = true;
    this.failed = false;
    this.generation += 1;
    const generation: number = this.generation;
    try {
      const page: SearchPage = await searchStore.search(query, this.offset, SearchConstants.PAGE_SIZE);
      if (generation !== this.generation) {
        return;
      }
      this.hits = reset ? page.hits : this.hits.concat(page.hits);
      this.total = page.total;
      this.hasMore = page.hasMore;
      this.offset = this.hits.length;
      if (reset) {
        searchStore.pushHistory(text);
        this.history = searchStore.history();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.warn('search failed: ' + error.message);
      if (generation === this.generation) {
        this.failed = true;
      }
    } finally {
      if (generation === this.generation) {
        this.searching = false;
      }
    }
  }
}

/** 全局唯一实例。 */
export const searchViewModel: SearchViewModel = new SearchViewModel();
