/*
 * ArticleActions.ets — 文章的外部操作（Model 层：剪贴板 / 系统分享 / 跳浏览器）。
 *
 * 三个动作都可能因设备能力缺失而失败（尤以系统分享依赖 HMS 为准），因此统一返回布尔值，
 * 由界面决定提示；不使用「抛异常 → 崩」的写法。
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ArticleActions';

/** 超链接的统一类型描述符（系统分享用）。 */
const UTD_HYPERLINK: string = 'general.hyperlink';

export class ArticleActions {
  /** 复制文本到系统剪贴板。 */
  async copyText(text: string): Promise<boolean> {
    if (text.length === 0) {
      return false;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'copyText failed: %{public}d', error.code);
      return false;
    }
  }

  /** 用系统浏览器打开链接。 */
  async openInBrowser(context: common.UIAbilityContext, url: string): Promise<boolean> {
    if (url.length === 0) {
      return false;
    }
    try {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      };
      await context.startAbility(want);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'openInBrowser failed: %{public}d', error.code);
      return false;
    }
  }

  /** 拉起系统分享面板（HMS ShareKit）。 */
  async share(context: common.UIAbilityContext, title: string, url: string): Promise<boolean> {
    if (url.length === 0) {
      return false;
    }
    try {
      const record: systemShare.SharedRecord = {
        utd: UTD_HYPERLINK,
        content: url,
        title: title
      };
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      const options: systemShare.ShareControllerOptions = {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DEFAULT
      };
      await controller.show(context, options);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'share failed: %{public}d', error.code);
      return false;
    }
  }
}

/** 全局唯一实例。 */
export const articleActions: ArticleActions = new ArticleActions();
