/*
 * ClipboardService.ets — 读取系统剪贴板文本（「添加订阅源」的粘贴 / 自动预填）。
 *
 * 读取可能因设备能力或系统策略失败（例如未授权读取剪贴板），一律吞掉异常返回空串，
 * 由调用方决定是否提示；不使用「抛异常 → 崩」的写法（与 ArticleActions 一致）。
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
