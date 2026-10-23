/*
 * ShareSheet.ets — 统一分享面板（纯状态管理 V2）。
 *
 * 三处入口（详情页 / 列表左滑 / 高亮页）复用同一个 bindSheet 内容组件：
 * 宿主先写 shareViewModel.context 再打开面板，本组件只做「展示 + 上报」，
 * 投递全部走 ShareViewModel → ShareService（目标 URL 构造在 ShareTargets，可单测）。
 *
 * 分组顺序固定：动作 → 外部目标 → 模板 → 高亮导出。
 * 不可用目标（缺链接 / 无高亮）置灰且给出原因；busy 期间整块不可点，避免重复拉起。
 * 所有结果统一用 Toast 反馈：成功提示、失败提示、拉起失败但已复制链接兜底。
 */

import { common } from '@kit.AbilityKit';
import { Article } from '../model/Feed';
import { Highlight } from '../model/Highlight';
import { ShareContext, ShareKind, ShareResult, ShareTarget, ShareTemplate } from '../model/Share';
import { ShareTargetId, targetById } from '../service/ShareTargets';
import { shareViewModel } from '../viewmodel/ShareViewModel';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { articleStore } from '../service/ArticleStore';
import { ToastUtil } from '../common/utils/ToastUtil';
import { MaterialController } from '../service/MaterialController';
import { appSettings } from '../model/AppSettings';

/** 动作组的目标 id（固定顺序，与 ShareTargets.targets() 一致）。 */
const ACTION_IDS: string[] = [
  ShareTargetId.SYSTEM,
  ShareTargetId.COPY_LINK,
  ShareTargetId.COPY_BODY,
  ShareTargetId.BROWSER,
  ShareTargetId.SAVED
];

/** 外部目标组的 id（固定顺序）。 */
const TARGET_IDS: string[] = [
  ShareTargetId.POCKET,
  ShareTargetId.INSTAPAPER,
  ShareTargetId.FLOMO,
  ShareTargetId.EMAIL
];

/**
 * 面板里的一行动作 / 目标。
 * 用 @ComponentV2 而不是多参 @Builder：busy / 置灰状态变化时整行要跟着刷新
 * （多参 @Builder 不参与动态刷新，见 ArkUI「@Builder 参数传递规则」）。
 */
@ComponentV2
struct ShareRow {
  @Param label: ResourceStr = '';
  /** 是否展示右侧原因文案（置灰时）。 */
  @Param showReason: boolean = false;
  @Param reason: ResourceStr = '';
  @Param rowEnabled: boolean = true;
  @Event onTap: () => void = () => {
  };

  build() {
    Row({ space: $r('app.float.space_s') }) {
      Text(this.label)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.showReason) {
        Text(this.reason)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    // 置灰用整体透明度：颜色仍走资源，不额外引入一份「禁用色」。
    .opacity(this.rowEnabled ? 1 : 0.4)
    .onClick(() => {
      if (this.rowEnabled) {
        this.onTap();
      }
    })
  }
}

/**
 * 模板行：名称 + 内容预览。
 * 点按弹出「复制 / 系统分享」二选一（bindMenu），模板本身不可直接编辑（管理在设置页）。
 */
@ComponentV2
struct ShareTemplateRow {
  @Param templateId: string = '';
  @Param name: string = '';
  @Param preview: string = '';
  @Param rowEnabled: boolean = true;
  @Event onCopy: (id: string) => void = () => {
  };
  @Event onShare: (id: string) => void = () => {
  };

  @Builder
  TemplateMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.tpl_copy') })
        .onClick(() => {
          this.onCopy(this.templateId);
        })
      MenuItem({ content: $r('app.string.tpl_share') })
        .onClick(() => {
          this.onShare(this.templateId);
        })
    }
    .radius($r('app.float.radius_card'))
  }

  build() {
    Row({ space: $r('app.float.space_s') }) {
      Column({ space: $r('app.float.space_xxs') }) {
        Text(this.name)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.preview)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_text_secondary')])
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    .opacity(this.rowEnabled ? 1 : 0.4)
    .enabled(this.rowEnabled)
    .bindMenu(this.TemplateMenu(), MaterialController.menuOptions({}, appSettings.immersiveOn))
  }
}

@ComponentV2
export struct ShareSheet {
  /** 宿主关闭面板（执行完动作 / 点空白回退时调用）。 */
  @Param onClose: () => void = () => {
  };
  /** 宿主 UIAbilityContext（startAbility / 系统分享 / 浏览器都需要）。 */
  @Require @Param ability: common.UIAbilityContext;

  /** 当前文章是否已在稍后读（决定「加入 / 取消」文案）。 */
  @Local savedAlready: boolean = false;
  /** 本篇高亮条数（0 = 「导出本篇高亮」置灰）。 */
  @Local articleHighlightCount: number = 0;

  aboutToAppear(): void {
    this.refreshForContext();
  }

  /**
   * 按当前上下文刷新「是否已稍后读」与「本篇高亮条数」。
   * bindSheet 的内容组件可能被复用，所以根节点 onAppear 也会再跑一次（幂等，读本地库）。
   */
  private refreshForContext(): void {
    const ctx: ShareContext = shareViewModel.context;
    this.savedAlready = false;
    this.articleHighlightCount = 0;
    if (ctx.articleId.length === 0) {
      return;
    }
    if (feedViewModel.hasArticle(ctx.articleId)) {
      this.savedAlready = feedViewModel.isSaved(ctx.articleId);
    } else {
      // 高亮页的文章可能不在当前列表（筛选 / 分页 / 已删除）：回库读一次，
      // 否则「加入 / 取消稍后读」的文案与实际状态会不一致。
      articleStore.loadById(ctx.articleId).then((article: Article | undefined) => {
        this.savedAlready = article !== undefined && article.saved;
      }).catch(() => {
        this.savedAlready = false;
      });
    }
    this.loadHighlightCount(ctx);
  }

  /** 预读本篇高亮条数：读取失败按 0 处理（点击时服务层还会再判一次）。 */
  private loadHighlightCount(ctx: ShareContext): void {
    if (ctx.kind !== ShareKind.ARTICLE || ctx.articleId.length === 0) {
      return;
    }
    articleStore.listHighlights(ctx.articleId).then((items: Highlight[]) => {
      this.articleHighlightCount = items.length;
    }).catch(() => {
      this.articleHighlightCount = 0;
    });
  }

  /** 当前上下文（@Trace，模板 / 动作都按它渲染）。 */
  private ctx(): ShareContext {
    return shareViewModel.context;
  }

  /** 动作 / 目标的文案：按 id 映射资源，避免动态拼 key。 */
  private labelOf(id: string): ResourceStr {
    if (id === ShareTargetId.SYSTEM) {
      return $r('app.string.share_action_system');
    }
    if (id === ShareTargetId.COPY_LINK) {
      return $r('app.string.share_action_copy_link');
    }
    if (id === ShareTargetId.COPY_BODY) {
      return $r('app.string.share_action_copy_body');
    }
    if (id === ShareTargetId.BROWSER) {
      return $r('app.string.share_action_browser');
    }
    if (id === ShareTargetId.SAVED) {
      return this.savedAlready
        ? $r('app.string.share_action_unsave')
        : $r('app.string.share_action_saved');
    }
    if (id === ShareTargetId.POCKET) {
      return $r('app.string.share_target_pocket');
    }
    if (id === ShareTargetId.INSTAPAPER) {
      return $r('app.string.share_target_instapaper');
    }
    if (id === ShareTargetId.FLOMO) {
      return $r('app.string.share_target_flomo');
    }
    return $r('app.string.share_target_email');
  }

  /** 结果 messageKey → 文案（服务层只回 key，UI 层负责映射）。 */
  private messageOf(key: string): ResourceStr {
    if (key === 'share_toast_copied') {
      return $r('app.string.share_toast_copied');
    }
    if (key === 'share_toast_copy_failed') {
      return $r('app.string.share_toast_copy_failed');
    }
    if (key === 'share_toast_open_failed') {
      return $r('app.string.share_toast_open_failed');
    }
    if (key === 'share_toast_fallback_copied') {
      return $r('app.string.share_toast_fallback_copied');
    }
    if (key === 'share_toast_share_failed') {
      return $r('app.string.share_toast_share_failed');
    }
    if (key === 'share_toast_nothing_to_share') {
      return $r('app.string.share_toast_nothing_to_share');
    }
    if (key === 'share_toast_busy') {
      return $r('app.string.share_toast_busy');
    }
    if (key === 'share_toast_saved') {
      return $r('app.string.share_toast_saved');
    }
    if (key === 'share_toast_unsaved') {
      return $r('app.string.share_toast_unsaved');
    }
    if (key === 'share_disabled_no_url') {
      return $r('app.string.share_disabled_no_url');
    }
    if (key === 'share_disabled_no_highlights') {
      return $r('app.string.share_disabled_no_highlights');
    }
    if (key === 'share_export_empty') {
      return $r('app.string.share_export_empty');
    }
    if (key === 'share_toast_shared') {
      return $r('app.string.share_toast_shared');
    }
    return $r('app.string.toast_action_failed');
  }

  /** 统一反馈：提示 + 关闭面板（busy 提示不关闭，用户可继续点）。 */
  private report(result: ShareResult): void {
    if (result.messageKey.length > 0) {
      ToastUtil.show(this.getUIContext(), this.messageOf(result.messageKey));
    }
    if (result.messageKey !== 'share_toast_busy') {
      this.onClose();
    }
  }

  /** 执行一个目标；「稍后读」走独立的切换路径（不进 ShareService 的副作用区）。 */
  private async runTarget(id: string): Promise<void> {
    if (id === ShareTargetId.SAVED) {
      await this.toggleSaved();
      return;
    }
    const result: ShareResult = await shareViewModel.runTarget(id, this.ability);
    this.report(result);
  }

  /** 稍后读切换：先按统一 busy 门控，再改文章状态并关闭面板。 */
  private async toggleSaved(): Promise<void> {
    const articleId: string = this.ctx().articleId;
    if (articleId.length === 0) {
      ToastUtil.show(this.getUIContext(), $r('app.string.share_toast_nothing_to_share'));
      return;
    }
    const wasSaved: boolean = this.savedAlready;
    const result: ShareResult = await shareViewModel.runTarget(ShareTargetId.SAVED, this.ability);
    if (result.messageKey === 'share_toast_busy') {
      ToastUtil.show(this.getUIContext(), this.messageOf(result.messageKey));
      return;
    }
    if (feedViewModel.hasArticle(articleId)) {
      feedViewModel.toggleSaved(articleId);
    } else {
      // 高亮页对应的文章可能不在已加载列表里：直接落库，避免「提示已加入但实际没写」。
      articleStore.setSaved(articleId, !wasSaved);
    }
    this.savedAlready = !wasSaved;
    ToastUtil.show(this.getUIContext(), wasSaved
      ? $r('app.string.share_toast_unsaved')
      : $r('app.string.share_toast_saved'));
    this.onClose();
  }

  /** 使用模板：copy = true 复制，否则交给系统分享。 */
  private async useTemplate(id: string, copy: boolean): Promise<void> {
    const result: ShareResult = await shareViewModel.runTemplate(id, copy, this.ability);
    this.report(result);
  }

  /** 导出本篇高亮（无高亮时按钮已置灰，这里再兜一次提示）。 */
  private async exportThisArticle(): Promise<void> {
    if (this.articleHighlightCount === 0) {
      ToastUtil.show(this.getUIContext(), $r('app.string.share_disabled_no_highlights'));
      return;
    }
    const result: ShareResult = await shareViewModel.exportThisArticle(this.ability);
    this.report(result);
  }

  /** 导出全部高亮。 */
  private async exportAll(): Promise<void> {
    const result: ShareResult = await shareViewModel.exportAll(this.ability);
    this.report(result);
  }

  /** 目标是否可点：目标自身可用 + 面板不在忙。 */
  private canRun(target: ShareTarget): boolean {
    return shareViewModel.targetEnabled(target) && !shareViewModel.busy;
  }

  /** 目标不可用原因（目前只有「缺链接」一种）。 */
  private reasonOf(target: ShareTarget): ResourceStr {
    const key: string = shareViewModel.disabledReasonKey(target);
    if (key === 'share_disabled_no_url') {
      return $r('app.string.share_disabled_no_url');
    }
    return '';
  }

  private isArticleContext(): boolean {
    return this.ctx().kind === ShareKind.ARTICLE;
  }

  /** 模板预览：把多行内容压成一行，够看出这是哪个格式即可。 */
  private previewOf(content: string): string {
    return content.replace(/\s+/g, ' ').trim();
  }

  @Builder
  SectionTitle(label: ResourceStr) {
    Text(label)
      .fontSize($r('app.float.font_size_section'))
      .fontColor($r('app.color.hm_text_secondary'))
      .margin({
        top: $r('app.float.space_s'),
        bottom: $r('app.float.space_xs'),
        left: $r('app.float.space_xs')
      })
  }

  private targetOf(id: string): ShareTarget | undefined {
    return targetById(id);
  }

  private enabledOf(id: string): boolean {
    const target: ShareTarget | undefined = this.targetOf(id);
    return target !== undefined && shareViewModel.targetEnabled(target);
  }

  private canRunOf(id: string): boolean {
    const target: ShareTarget | undefined = this.targetOf(id);
    return target !== undefined && this.canRun(target);
  }

  private reasonOfId(id: string): ResourceStr {
    const target: ShareTarget | undefined = this.targetOf(id);
    return target === undefined ? '' : this.reasonOf(target);
  }

  @Builder
  ActionsSection() {
    this.SectionTitle($r('app.string.share_group_actions'))
    Column() {
      ForEach(ACTION_IDS, (id: string, index: number) => {
        if (index > 0) {
          Divider().color($r('app.color.hm_divider'))
        }
        ShareRow({
          label: this.labelOf(id),
          showReason: !this.enabledOf(id),
          reason: this.reasonOfId(id),
          rowEnabled: this.canRunOf(id),
          onTap: () => {
            this.runTarget(id);
          }
        })
      }, (id: string) => 'act_' + id)
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  @Builder
  TargetsSection() {
    this.SectionTitle($r('app.string.share_group_targets'))
    Column() {
      ForEach(TARGET_IDS, (id: string, index: number) => {
        if (index > 0) {
          Divider().color($r('app.color.hm_divider'))
        }
        ShareRow({
          label: this.labelOf(id),
          showReason: !this.enabledOf(id),
          reason: this.reasonOfId(id),
          rowEnabled: this.canRunOf(id),
          onTap: () => {
            this.runTarget(id);
          }
        })
      }, (id: string) => 'tgt_' + id)
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  @Builder
  TemplatesSection() {
    this.SectionTitle($r('app.string.share_group_templates'))
    Column() {
      if (shareViewModel.templates.length === 0) {
        Text($r('app.string.tpl_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .padding($r('app.float.space_m'))
      } else {
        ForEach(shareViewModel.templates, (template: ShareTemplate, index: number) => {
          if (index > 0) {
            Divider().color($r('app.color.hm_divider'))
          }
          ShareTemplateRow({
            templateId: template.id,
            name: template.name,
            preview: this.previewOf(template.content),
            rowEnabled: !shareViewModel.busy,
            onCopy: (id: string) => {
              this.useTemplate(id, true);
            },
            onShare: (id: string) => {
              this.useTemplate(id, false);
            }
          })
        }, (template: ShareTemplate) => template.id)
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  @Builder
  ExportSection() {
    this.SectionTitle($r('app.string.share_group_export'))
    Column() {
      if (this.isArticleContext()) {
        ShareRow({
          label: $r('app.string.share_export_article'),
          showReason: this.articleHighlightCount === 0,
          reason: $r('app.string.share_disabled_no_highlights'),
          rowEnabled: this.articleHighlightCount > 0 && !shareViewModel.busy,
          onTap: () => {
            this.exportThisArticle();
          }
        })
        Divider().color($r('app.color.hm_divider'))
      }
      ShareRow({
        label: $r('app.string.share_export_all'),
        rowEnabled: !shareViewModel.busy,
        onTap: () => {
          this.exportAll();
        }
      })
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  build() {
    Column({ space: $r('app.float.space_xs') }) {
      Text($r('app.string.share_panel_title'))
        .fontSize($r('app.float.font_size_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      Scroll() {
        Column() {
          this.ActionsSection()
          this.TargetsSection()
          this.TemplatesSection()
          this.ExportSection()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      // 面板高度由宿主 bindSheet 决定；内容超出时内部滚动，避免把面板撑破。
      .constraintSize({ maxHeight: 560 })
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .padding($r('app.float.space_l'))
    .alignItems(HorizontalAlign.Start)
    .onAppear(() => {
      // 面板内容被复用 / 再次打开时，重新按当前上下文刷新置灰与文案。
      this.refreshForContext();
    })
  }
}
