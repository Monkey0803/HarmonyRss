/*
 * ClipboardService.ets — 读取系统剪贴板文本（「添加订阅源」的粘贴 / 自动预填）。
 *
 * 读取受系统权限管控：必须由用户在「粘贴控件（PasteButton）」上主动点击后调用，
 * 系统会临时授予本次读取权限；不要在打开页面时静默读取（会返回 12900010）。
 * 任何失败（未授权 / 非文本 / 系统异常）一律吞掉并返回空串，由调用方提示。
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClipboardService';

export class ClipboardService {
  /** 读取系统剪贴板的纯文本 / HTML 文本；失败或非文本时返回空串。 */
  async readText(): Promise<string> {
    try {
      const system: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const data: pasteboard.PasteData = await system.getData();
      const primary: string = data.getPrimaryMimeType();
      if (primary === pasteboard.MIMETYPE_TEXT_PLAIN || primary === pasteboard.MIMETYPE_TEXT_HTML) {
        return data.getPrimaryText();
      }
      return '';
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'readText failed: %{public}d', error.code);
      return '';
    }
  }
}

/** 全局唯一实例。 */
export const clipboardService: ClipboardService = new ClipboardService();
