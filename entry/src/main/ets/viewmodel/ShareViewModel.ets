/*
 * ShareViewModel.ets — 统一分享面板的状态与编排（@ObservedV2）。
 *
 * 面板 / 入口只读这里的 context、templates、busy、lastResult；具体投递全部交给 ShareService，
 * 模板持久化交给 ShareTemplates。所有分享动作都要求宿主传入 UIAbilityContext —— 不缓存窗口上下文，
 * 避免 Ability 重建后拿到失效对象。
 *
 * 「稍后读」是 INTERNAL 目标：这里只返回结果并给出提示，真正的 toggleSaved 由调用方处理
 * （ShareViewModel 不依赖 FeedViewModel，避免编排层循环依赖）。
 */

import { common } from '@kit.AbilityKit';
import { ShareContext, ShareResult, ShareTarget, ShareTemplate } from '../model/Share';
import { ShareTargetId, targets as listTargets } from '../service/ShareTargets';
import { shareService } from '../service/ShareService';
import { shareTemplates, render as renderTemplate } from '../service/ShareTemplates';
import { articleActions } from '../service/ArticleActions';

@ObservedV2
export class ShareViewModel {
  /** 当前分享上下文（面板关闭时是空上下文）。 */
  @Trace context: ShareContext = ShareContext.empty();
  /** 模板列表（按 sort 升序；无自定义模板时是默认模板）。 */
  @Trace templates: ShareTemplate[] = [];
  /** 正在执行目标 / 导出，防连点重复拉起。 */
  @Trace busy: boolean = false;
  /** 最近一次动作结果（宿主据此 Toast）。 */
  @Trace lastResult: ShareResult = new ShareResult(false);

  /**
   * 初始化模板库（管理页进入时调用）：只打开偏好库并刷新模板，不改动分享上下文。
   * 面板路径用 open(ability, ctx)，它内部也走这里同一套打开 + 刷新逻辑。
   */
  async init(ability: common.UIAbilityContext): Promise<void> {
    await shareTemplates.open(ability);
    await this.reloadTemplates();
  }

  /** 打开面板：记录上下文，并确保模板库已打开 + 刷新模板。 */
  async open(ability: common.UIAbilityContext, ctx: ShareContext): Promise<void> {
    this.context = ctx;
    this.busy = false;
    this.lastResult = new ShareResult(false);
    await shareTemplates.open(ability);
    await this.reloadTemplates();
  }

  /** 关闭面板：清空上下文，避免下次打开闪出旧内容。 */
  close(): void {
    this.context = ShareContext.empty();
    this.busy = false;
  }

  /** 固定顺序的目标列表。 */
  targets(): ShareTarget[] {
    return listTargets();
  }

  /** 目标是否可用（缺链接时置灰）。 */
  targetEnabled(target: ShareTarget): boolean {
    return !(target.requiresUrl && this.context.url.length === 0);
  }

  /** 目标不可用的原因 key；可用时返回空串。 */
  disabledReasonKey(target: ShareTarget): string {
    return this.targetEnabled(target) ? '' : 'share_disabled_no_url';
  }

  /** 执行目标；busy 时直接返回提示结果，避免重复拉起 / 重复复制。 */
  async runTarget(id: string, ability: common.UIAbilityContext): Promise<ShareResult> {
    if (this.busy) {
      return new ShareResult(false, id, false, 'share_toast_busy');
    }
    this.busy = true;
    try {
      const result: ShareResult = await shareService.execute(id, this.context, ability);
      // 稍后读由调用方真正执行；这里只负责给出可用的提示。
      this.lastResult = id === ShareTargetId.SAVED
        ? new ShareResult(result.ok, id, result.fallbackCopied, 'share_toast_saved')
        : result;
      return this.lastResult;
    } finally {
      this.busy = false;
    }
  }

  /** 使用模板：copy = true 复制到剪贴板，否则交给系统分享。 */
  async runTemplate(id: string, copy: boolean, ability: common.UIAbilityContext): Promise<ShareResult> {
    if (this.busy) {
      return new ShareResult(false, id, false, 'share_toast_busy');
    }
    let template: ShareTemplate | undefined = undefined;
    for (let i = 0; i < this.templates.length; i += 1) {
      if (this.templates[i].id === id) {
        template = this.templates[i];
        break;
      }
    }
    if (template === undefined) {
      return new ShareResult(false, id, false, 'share_toast_nothing_to_share');
    }
    const text: string = renderTemplate(template, this.context);
    if (text.trim().length === 0) {
      return new ShareResult(false, id, false, 'share_toast_nothing_to_share');
    }
    this.busy = true;
    try {
      let ok: boolean = false;
      if (copy) {
        ok = await articleActions.copyText(text);
      } else {
        ok = await articleActions.shareText(ability, this.context.title, text);
      }
      const messageKey: string = ok
        ? (copy ? 'share_toast_copied' : 'share_toast_shared')
        : (copy ? 'share_toast_copy_failed' : 'share_toast_share_failed');
      this.lastResult = new ShareResult(ok, id, false, messageKey);
      return this.lastResult;
    } finally {
      this.busy = false;
    }
  }

  /** 导出本篇高亮（Markdown → 系统分享）。 */
  async exportThisArticle(ability: common.UIAbilityContext): Promise<ShareResult> {
    if (this.busy) {
      return new ShareResult(false, 'exportArticle', false, 'share_toast_busy');
    }
    this.busy = true;
    try {
      this.lastResult = await shareService.exportArticleHighlights(this.context.articleId,
        this.context.title, this.context.url, this.context.feedTitle, ability);
      return this.lastResult;
    } finally {
      this.busy = false;
    }
  }

  /** 导出全部高亮（Markdown → 系统分享）。 */
  async exportAll(ability: common.UIAbilityContext): Promise<ShareResult> {
    if (this.busy) {
      return new ShareResult(false, 'exportAll', false, 'share_toast_busy');
    }
    this.busy = true;
    try {
      this.lastResult = await shareService.exportAllHighlights(ability);
      return this.lastResult;
    } finally {
      this.busy = false;
    }
  }

  /** 重新读取模板（设置页增删改后调用）。 */
  async reloadTemplates(): Promise<void> {
    this.templates = await shareTemplates.list();
  }
}

/** 全局唯一实例。 */
export const shareViewModel: ShareViewModel = new ShareViewModel();
