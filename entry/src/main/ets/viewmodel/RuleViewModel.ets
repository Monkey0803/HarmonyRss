/*
 * RuleViewModel.ets — 规则列表 / 编辑 / 试运行 / 已隐藏列表的编排（@ObservedV2）。
 *
 * 页面只与本 ViewModel 交互：校验在这里做（返回 RuleError 常量），落库交给 RuleStore，
 * 试运行交给 RuleService（只读），已隐藏列表直接读 ArticleStore 的专用查询。
 */

import { Article } from '../model/Feed';
import { Rule, RuleAction, RuleDraft, RuleError, RuleField, RuleTestResult, draftOf } from '../model/Rule';
import { RuleConstants } from '../common/constants/RssConstants';
import { ruleStore } from '../service/RuleStore';
import { ruleService } from '../service/RuleService';
import { articleStore } from '../service/ArticleStore';
import { validateDraft } from '../service/RuleEngine';

@ObservedV2
export class RuleViewModel {
  /** 全部规则（按优先级升序）。 */
  @Trace rules: Rule[] = [];
  @Trace loading: boolean = false;
  @Trace failed: boolean = false;
  /** 最近一次校验失败的原因（RuleError 常量；成功时回到 NONE）。 */
  @Trace lastError: string = RuleError.NONE;
  /** 正在编辑的规则 id（空串 = 新建）。 */
  @Trace editingId: string = '';
  /** 编辑态草稿；undefined 表示不在编辑态。 */
  @Trace editing: RuleDraft | undefined = undefined;
  /** 最近一次试运行结果；undefined 表示还没跑过。 */
  @Trace testResult: RuleTestResult | undefined = undefined;
  /** 正在试运行的规则 id（空串 = 没有在跑）。 */
  @Trace testingId: string = '';
  /** 被规则隐藏的文章数（规则页入口计数）。 */
  @Trace hiddenCount: number = 0;
  /** 已隐藏文章列表（轻量列，打开时再按需加载正文）。 */
  @Trace hiddenArticles: Article[] = [];
  /** 变更版本号（订阅页入口计数读它建立刷新依赖）。 */
  @Trace revision: number = 0;

  /** 读取规则列表。 */
  async load(): Promise<void> {
    this.loading = true;
    this.failed = false;
    try {
      this.rules = await ruleStore.list();
      this.revision += 1;
    } catch (err) {
      this.failed = true;
    } finally {
      this.loading = false;
    }
  }

  /** 规则数量（订阅页入口计数）。 */
  count(): number {
    return this.rules.length;
  }

  /** 进入新建态：默认勾选全部字段，动作为空（避免误打标 / 误隐藏）。 */
  beginCreate(): void {
    this.editingId = '';
    this.editing = new RuleDraft('', true, [], RuleField.all(), [], [], []);
    this.lastError = RuleError.NONE;
    this.testResult = undefined;
  }

  /** 进入编辑态（预填规则当前值）。 */
  beginEdit(rule: Rule): void {
    this.editingId = rule.id;
    this.editing = draftOf(rule);
    this.lastError = RuleError.NONE;
    this.testResult = undefined;
  }

  /** 退出编辑态。 */
  cancelEdit(): void {
    this.editingId = '';
    this.editing = undefined;
    this.lastError = RuleError.NONE;
  }

  /**
   * 新建：先校验（含数量上限），通过后落库并刷新列表。
   * 返回 false 时读 lastError 说明原因。
   */
  async create(draft: RuleDraft): Promise<boolean> {
    if (this.rules.length === 0) {
      await this.load();
    }
    const error: string = validateDraft(draft);
    this.lastError = error;
    if (error !== RuleError.NONE) {
      return false;
    }
    if (this.rules.length >= RuleConstants.MAX_RULES) {
      this.lastError = RuleError.LIMIT_REACHED;
      return false;
    }
    try {
      const created: Rule | undefined = await ruleStore.create(draft);
      if (created === undefined) {
        return false;
      }
      this.lastError = RuleError.NONE;
      this.editingId = '';
      this.editing = undefined;
      await this.load();
      return true;
    } catch (err) {
      return false;
    }
  }

  /** 编辑：校验同新建，但不检查数量上限。 */
  async update(id: string, draft: RuleDraft): Promise<boolean> {
    const error: string = validateDraft(draft);
    this.lastError = error;
    if (error !== RuleError.NONE) {
      return false;
    }
    try {
      const ok: boolean = await ruleStore.update(id, draft);
      if (ok) {
        this.lastError = RuleError.NONE;
        this.editingId = '';
        this.editing = undefined;
        await this.load();
      }
      return ok;
    } catch (err) {
      return false;
    }
  }

  /** 删除规则。 */
  async remove(id: string): Promise<void> {
    try {
      await ruleStore.remove(id);
    } catch (err) {
      return;
    }
    if (this.editingId === id) {
      this.cancelEdit();
    }
    if (this.testingId === id) {
      this.testingId = '';
      this.testResult = undefined;
    }
    await this.load();
  }

  /** 启停规则。 */
  async setEnabled(id: string, enabled: boolean): Promise<void> {
    try {
      await ruleStore.setEnabled(id, enabled);
    } catch (err) {
      return;
    }
    await this.load();
  }

  /** 上移 / 下移（delta = -1 / 1）。 */
  async move(id: string, delta: number): Promise<void> {
    try {
      await ruleStore.move(id, delta);
    } catch (err) {
      return;
    }
    await this.load();
  }

  /**
   * 试运行：最近 limit 篇只统计不写入（limit <= 0 用默认 500）。
   * 结果放在 testResult；同时记录 testingId 供界面显示 loading。
   */
  async testRun(id: string, limit: number = RuleConstants.RULE_TEST_SAMPLE): Promise<void> {
    this.testingId = id;
    this.testResult = undefined;
    try {
      this.testResult = await ruleService.testRun(id, limit);
    } finally {
      this.testingId = '';
    }
  }

  /** 读取已隐藏文章列表与数量。 */
  async loadHidden(): Promise<void> {
    try {
      const articles: Article[] = await articleStore.loadHidden();
      const total: number = await articleStore.countHidden();
      this.hiddenArticles = articles;
      this.hiddenCount = total;
      this.revision += 1;
    } catch (err) {
      this.hiddenArticles = [];
      this.hiddenCount = 0;
    }
  }

  /** 刷新已隐藏计数（规则页入口用，不加载整份列表）。 */
  async refreshHiddenCount(): Promise<void> {
    try {
      this.hiddenCount = await articleStore.countHidden();
    } catch (err) {
      this.hiddenCount = 0;
    }
  }

  /** 取消隐藏 / 批量隐藏：写库后同步内存列表与计数。 */
  async setHidden(ids: string[], hidden: boolean): Promise<void> {
    if (ids.length === 0) {
      return;
    }
    articleStore.setHiddenMany(ids, hidden);
    const wanted: Set<string> = new Set<string>();
    for (let i = 0; i < ids.length; i += 1) {
      wanted.add(ids[i]);
    }
    for (let i = 0; i < this.hiddenArticles.length; i += 1) {
      if (wanted.has(this.hiddenArticles[i].id)) {
        this.hiddenArticles[i].hidden = hidden;
      }
    }
    if (!hidden) {
      const kept: Article[] = [];
      for (let i = 0; i < this.hiddenArticles.length; i += 1) {
        if (!wanted.has(this.hiddenArticles[i].id)) {
          kept.push(this.hiddenArticles[i]);
        }
      }
      this.hiddenArticles = kept;
    }
    await this.refreshHiddenCount();
    this.revision += 1;
  }

  /** 动作是否被草稿勾选（编辑页 chips 用）。 */
  hasAction(action: string): boolean {
    return this.editing !== undefined && this.editing.actions.indexOf(action) >= 0;
  }

  /** 新建草稿的默认动作（供编辑页「全不选」时重置）。 */
  static defaultActions(): string[] {
    return [RuleAction.READ];
  }
}

/** 全局唯一 ViewModel。 */
export const ruleViewModel: RuleViewModel = new RuleViewModel();
