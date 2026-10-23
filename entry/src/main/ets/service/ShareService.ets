/*
 * ShareService.ets — 分享上下文构建、目标执行与高亮导出（编排层）。
 *
 * 只依赖 ArticleActions / TagStore / ArticleStore / HighlightExport，**不依赖任何 ViewModel**：
 * 「加入稍后读」等应用内动作以 INTERNAL 结果返回，由宿主自行处理，避免服务层反向依赖 UI 状态。
 *
 * 失败策略（与 FR-004 一致）：
 *   - scheme / mailto 拉起失败 → 提示「无法打开」并自动复制链接，fallbackCopied = true；
 *   - 系统分享 / 浏览器失败 → 返回失败 + 提示 key，不静默；
 *   - 缺链接 / 缺正文 → 直接返回带提示 key 的失败结果，不发起任何请求。
 */

import { common, Want } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { Highlight, HighlightLibraryItem } from '../model/Highlight';
import { ShareContext, ShareKind, ShareResult, ShareTarget } from '../model/Share';
import { articleActions } from './ArticleActions';
import { tagStore } from './TagStore';
import { articleStore } from './ArticleStore';
import { toMarkdown } from './HighlightExport';
import { buildUri, ShareTargetId, targetById } from './ShareTargets';
import { CommonConstants } from '../common/constants/CommonConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'ShareService';

/** 截断超长文本（与系统分享 / 剪贴板承载上限一致）。 */
function clip(text: string): string {
  return text.length > CommonConstants.SHARE_TEXT_MAX_CHARS
    ? text.substring(0, CommonConstants.SHARE_TEXT_MAX_CHARS)
    : text;
}

/** 取分享正文：正文优先，其次高亮引文 + 备注，最后摘要素材。 */
function bodyOf(ctx: ShareContext): string {
  if (ctx.body.length > 0) {
    return ctx.body;
  }
  if (ctx.quote.length > 0) {
    return ctx.note.length > 0 ? ctx.quote + '\n\n' + ctx.note : ctx.quote;
  }
  if (ctx.summary.length > 0) {
    return ctx.summary;
  }
  return ctx.title;
}

export class ShareService {
  /** 文章 → 统一上下文（补本地标签）。 */
  async articleContext(article: Article): Promise<ShareContext> {
    const names: string[] = [];
    try {
      const tags = await tagStore.tagsOfArticle(article.id);
      for (let i = 0; i < tags.length; i += 1) {
        names.push(tags[i].name);
      }
    } catch (err) {
      // 标签读失败不影响分享主体。
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'articleContext tags failed: %{public}d', error.code);
    }
    const body: string = article.plainText.length > 0 ? article.plainText : article.content;
    return new ShareContext(ShareKind.ARTICLE, article.title, article.link, article.summary,
      article.author, names, body, '', '', article.id, article.feedTitle);
  }

  /** 单条高亮 → 上下文（引文 + 备注 + 所属文章链接）。 */
  highlightContext(item: HighlightLibraryItem): ShareContext {
    const quote: string = item.highlight.quote;
    const note: string = item.highlight.note;
    const body: string = note.length > 0 ? quote + '\n\n' + note : quote;
    return new ShareContext(ShareKind.HIGHLIGHT, item.articleTitle, item.articleLink, '', '',
      [], body, quote, note, item.highlight.articleId, item.feedTitle);
  }

  /**
   * 执行一个分享目标。
   * INTERNAL（稍后读）不在此处产生副作用：返回 ok 结果，由调用方决定后续。
   */
  async execute(targetId: string, ctx: ShareContext, ability: common.UIAbilityContext): Promise<ShareResult> {
    const target: ShareTarget | undefined = targetById(targetId);
    if (target === undefined) {
      return new ShareResult(false, targetId, false, 'share_disabled_no_url');
    }

    if (targetId === ShareTargetId.SYSTEM) {
      if (ctx.url.length === 0) {
        return new ShareResult(false, targetId, false, 'share_disabled_no_url');
      }
      const ok: boolean = await articleActions.share(ability, ctx.title, ctx.url);
      return new ShareResult(ok, targetId, false, ok ? 'share_toast_shared' : 'share_toast_share_failed');
    }

    if (targetId === ShareTargetId.COPY_LINK) {
      if (ctx.url.length === 0) {
        return new ShareResult(false, targetId, false, 'share_disabled_no_url');
      }
      const ok: boolean = await articleActions.copyText(ctx.url);
      return new ShareResult(ok, targetId, false, ok ? 'share_toast_copied' : 'share_toast_copy_failed');
    }

    if (targetId === ShareTargetId.COPY_BODY) {
      const text: string = clip(bodyOf(ctx));
      if (text.length === 0) {
        return new ShareResult(false, targetId, false, 'share_toast_nothing_to_share');
      }
      const ok: boolean = await articleActions.copyText(text);
      return new ShareResult(ok, targetId, false, ok ? 'share_toast_copied' : 'share_toast_copy_failed');
    }

    if (targetId === ShareTargetId.BROWSER) {
      if (ctx.url.length === 0) {
        return new ShareResult(false, targetId, false, 'share_disabled_no_url');
      }
      const ok: boolean = await articleActions.openInBrowser(ability, ctx.url);
      return new ShareResult(ok, targetId, false, ok ? '' : 'share_toast_open_failed');
    }

    if (targetId === ShareTargetId.SAVED) {
      // 应用内动作：调用方（ViewModel / 视图）据此调用「加入稍后读」。
      return new ShareResult(true, targetId, false, '');
    }

    // scheme / mailto：统一走 viewData。
    const uri: string = buildUri(targetId, ctx);
    if (uri.length === 0) {
      return new ShareResult(false, targetId, false, 'share_disabled_no_url');
    }
    // 先判断是否有应用能处理该 scheme：目标未安装时 startAbility 不会抛错，
    // 而是由系统弹「暂无可用打开方式」，兜底复制就永远不触发（FR-004 / US2-5）。
    if (!this.canOpenUri(uri)) {
      const copied: boolean = ctx.url.length > 0 ? await articleActions.copyText(ctx.url) : false;
      return new ShareResult(false, targetId, copied,
        copied ? 'share_toast_fallback_copied' : 'share_toast_open_failed');
    }
    try {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: uri
      };
      await ability.startAbility(want);
      return new ShareResult(true, targetId, false, '');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'execute %{public}s failed: %{public}d', targetId, error.code);
      const copied: boolean = ctx.url.length > 0 ? await articleActions.copyText(ctx.url) : false;
      return new ShareResult(false, targetId, copied,
        copied ? 'share_toast_fallback_copied' : 'share_toast_open_failed');
    }
  }

  /**
   * 是否有应用能处理该 URI。
   * canOpenLink 依赖 module.json5 的 querySchemes；未声明时会抛错，
   * 此时退回 true（交给 startAbility 的原有失败路径），不阻断分享。
   */
  private canOpenUri(uri: string): boolean {
    try {
      return bundleManager.canOpenLink(uri);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'canOpenLink failed: %{public}d', error.code);
      return true;
    }
  }

  /**
   * 导出单篇文章的全部高亮为 Markdown 并交给系统分享。
   * 无高亮时不发起分享，返回提示 key（视图据此置灰 / Toast）。
   */
  async exportArticleHighlights(articleId: string, title: string, link: string, feedTitle: string,
    ability: common.UIAbilityContext): Promise<ShareResult> {
    const highlights: Highlight[] = await articleStore.listHighlights(articleId);
    if (highlights.length === 0) {
      return new ShareResult(false, ShareTargetId.COPY_BODY, false, 'share_disabled_no_highlights');
    }
    const items: HighlightLibraryItem[] = [];
    for (let i = 0; i < highlights.length; i += 1) {
      items.push(new HighlightLibraryItem(highlights[i], title, link, feedTitle));
    }
    const markdown: string = toMarkdown(items, '');
    if (markdown.length === 0) {
      return new ShareResult(false, ShareTargetId.COPY_BODY, false, 'share_disabled_no_highlights');
    }
    const ok: boolean = await articleActions.shareText(ability,
      title.length > 0 ? title : this.exportLabel(ability), markdown);
    return new ShareResult(ok, ShareTargetId.COPY_BODY, false, ok ? '' : 'share_toast_share_failed');
  }

  /** 导出全部高亮为 Markdown（按文章分组）并交给系统分享。 */
  async exportAllHighlights(ability: common.UIAbilityContext): Promise<ShareResult> {
    const items: HighlightLibraryItem[] = await articleStore.listAllHighlights();
    if (items.length === 0) {
      return new ShareResult(false, ShareTargetId.COPY_BODY, false, 'share_export_empty');
    }
    const markdown: string = toMarkdown(items, '');
    const ok: boolean = await articleActions.shareText(ability, this.exportLabel(ability), markdown);
    return new ShareResult(ok, ShareTargetId.COPY_BODY, false, ok ? '' : 'share_toast_share_failed');
  }

  /** 系统分享标题的本地化兜底（资源缺失时用英文）。 */
  private exportLabel(ability: common.UIAbilityContext): string {
    try {
      return ability.resourceManager.getStringSync($r('app.string.share_export_all').id);
    } catch (err) {
      return 'Highlights';
    }
  }
}

/** 全局唯一实例。 */
export const shareService: ShareService = new ShareService();
