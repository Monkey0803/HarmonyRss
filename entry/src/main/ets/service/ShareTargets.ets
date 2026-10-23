/*
 * ShareTargets.ets — 分享目标注册表与 URL 构造（纯函数，无副作用，方便单测）。
 *
 * 第一版只做免 Key 目标：系统能力 / 剪贴板 / 浏览器 + Pocket / Instapaper / Flomo / mailto。
 * 所有参数统一走 encodeURIComponent：URL 里的中文、空格、& 等不会破坏 query。
 * 需要链接的目标在缺 url 时返回空串，由调用方置灰或提示，避免拉起一个空页面。
 */

import { ShareContext, ShareTarget, ShareTargetType } from '../model/Share';

/** 邮件正文里摘要的最大字符数（太长会超过 mailto 的实用长度）。 */
const MAIL_SUMMARY_MAX: number = 300;

/** 目标 id（服务与视图共用，避免魔法字符串）。 */
export class ShareTargetId {
  static readonly SYSTEM: string = 'system';
  static readonly COPY_LINK: string = 'copyLink';
  static readonly COPY_BODY: string = 'copyBody';
  static readonly BROWSER: string = 'browser';
  static readonly SAVED: string = 'saved';
  static readonly POCKET: string = 'pocket';
  static readonly INSTAPAPER: string = 'instapaper';
  static readonly FLOMO: string = 'flomo';
  static readonly EMAIL: string = 'email';
}

/** 统一编码：encodeURIComponent 已覆盖中文 / 空格 / & / # 等。 */
export function encode(value: string): string {
  return encodeURIComponent(value);
}

/** 固定顺序的目标列表（面板按此顺序分组展示）。 */
export function targets(): ShareTarget[] {
  return [
    new ShareTarget(ShareTargetId.SYSTEM, 'share_action_system', ShareTargetType.SYSTEM, true),
    new ShareTarget(ShareTargetId.COPY_LINK, 'share_action_copy_link', ShareTargetType.CLIPBOARD, true),
    new ShareTarget(ShareTargetId.COPY_BODY, 'share_action_copy_body', ShareTargetType.CLIPBOARD, false),
    new ShareTarget(ShareTargetId.BROWSER, 'share_action_browser', ShareTargetType.SYSTEM, true),
    new ShareTarget(ShareTargetId.SAVED, 'share_action_saved', ShareTargetType.INTERNAL, false),
    new ShareTarget(ShareTargetId.POCKET, 'share_target_pocket', ShareTargetType.SCHEME, true),
    new ShareTarget(ShareTargetId.INSTAPAPER, 'share_target_instapaper', ShareTargetType.SCHEME, true),
    new ShareTarget(ShareTargetId.FLOMO, 'share_target_flomo', ShareTargetType.SCHEME, true),
    new ShareTarget(ShareTargetId.EMAIL, 'share_target_email', ShareTargetType.MAILTO, true)
  ];
}

/** 按 id 找目标；未知 id 返回 undefined。 */
export function targetById(id: string): ShareTarget | undefined {
  const list: ShareTarget[] = targets();
  for (let i = 0; i < list.length; i += 1) {
    if (list[i].id === id) {
      return list[i];
    }
  }
  return undefined;
}

/** 截断摘要并去掉换行（query 里的换行会被编码成 %0A，可读性差）。 */
function mailSummary(summary: string): string {
  const singleLine: string = summary.replace(/\s+/g, ' ').trim();
  if (singleLine.length <= MAIL_SUMMARY_MAX) {
    return singleLine;
  }
  return singleLine.substring(0, MAIL_SUMMARY_MAX) + '…';
}

/** 拼 Flomo 内容：标题 + 链接。 */
function flomoContent(ctx: ShareContext): string {
  if (ctx.title.length === 0) {
    return ctx.url;
  }
  return ctx.title + '\n' + ctx.url;
}

/** 拼邮件正文：标题 / 链接 / 摘要，摘要截断；空段自动跳过。 */
function mailBody(ctx: ShareContext): string {
  const parts: string[] = [];
  if (ctx.title.length > 0) {
    parts.push(ctx.title);
  }
  parts.push(ctx.url);
  const summary: string = mailSummary(ctx.summary);
  if (summary.length > 0) {
    parts.push(summary);
  }
  return parts.join('\n\n');
}

/**
 * 构造目标 URI。仅支持 scheme / mailto 目标；缺 url（或需要正文却为空）时返回空串。
 * 其它目标（system / clipboard / internal）没有 URI，一律返回空串。
 */
export function buildUri(id: string, ctx: ShareContext): string {
  if (ctx.url.length === 0) {
    return '';
  }
  if (id === ShareTargetId.POCKET) {
    return 'pocket://add?url=' + encode(ctx.url) + '&title=' + encode(ctx.title);
  }
  if (id === ShareTargetId.INSTAPAPER) {
    return 'instapaper://x-callback-url/add?url=' + encode(ctx.url) + '&title=' + encode(ctx.title);
  }
  if (id === ShareTargetId.FLOMO) {
    return 'flomo://create?content=' + encode(flomoContent(ctx));
  }
  if (id === ShareTargetId.EMAIL) {
    return 'mailto:?subject=' + encode(ctx.title) + '&body=' + encode(mailBody(ctx));
  }
  return '';
}
