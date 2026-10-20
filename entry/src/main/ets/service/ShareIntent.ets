/*
 * ShareIntent.ets — 从「分享进来」的 Want 里提取可订阅地址。
 *
 * 分享来源 App 各异，携带分享内容的参数 key 也可能不同；这里对常见 key 做尽力而为的提取，
 * 命中即用，全部落空则返回空数组（页面据此提示用户手动输入）。
 *
 * 注意：ArkTS 禁止对 Object 做动态属性访问，因此只能按字面量 key 逐个取，不能遍历 key 数组。
 */

import { Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { UrlText } from '../common/utils/UrlText';

/** 把任意参数值转成字符串；非字符串（数字 / 数组 / 缓冲区等）统一 toString 后交给 URL 提取过滤。 */
function textOf(value: Object | undefined): string {
  if (value === undefined) {
    return '';
  }
  return value.toString();
}

export class ShareIntent {
  /**
   * 从官方解析出的分享数据里提取可订阅地址（文本 / 链接记录）。
   * 这是接收分享的首选路径（`systemShare.getSharedData`）。
   */
  extractFromSharedData(data: systemShare.SharedData): string[] {
    const found: string[] = [];
    const seen: Set<string> = new Set();
    const records: systemShare.SharedRecord[] = data.getRecords();
    for (let i = 0; i < records.length; i += 1) {
      const record: systemShare.SharedRecord = records[i];
      ShareIntent.add(found, seen, record.content);
      ShareIntent.add(found, seen, record.uri);
      ShareIntent.add(found, seen, record.title);
    }
    return found;
  }

  /** 尽力从 want 参数里提取可订阅的 http(s) 地址（兜底，getSharedData 失败时用）。 */
  extractSharedUrls(want: Want): string[] {
    const found: string[] = [];
    const seen: Set<string> = new Set();
    ShareIntent.add(found, seen, want.uri !== undefined ? want.uri : '');
    const params: Record<string, Object> | undefined = want.parameters;
    if (params !== undefined) {
      ShareIntent.add(found, seen, textOf(params['ohos.extra.param.key.content']));
      ShareIntent.add(found, seen, textOf(params['ohos.extra.param.key.shareUrl']));
      ShareIntent.add(found, seen, textOf(params['ohos.extra.param.key.contentTitle']));
      ShareIntent.add(found, seen, textOf(params['content']));
      ShareIntent.add(found, seen, textOf(params['text']));
      ShareIntent.add(found, seen, textOf(params['url']));
    }
    return found;
  }

  private static add(found: string[], seen: Set<string>, text: string | undefined): void {
    if (text === undefined || text.length === 0) {
      return;
    }
    const urls: string[] = UrlText.extractUrls(text);
    for (let i = 0; i < urls.length; i += 1) {
      if (!seen.has(urls[i])) {
        seen.add(urls[i]);
        found.push(urls[i]);
      }
    }
  }
}

/** 全局唯一实例。 */
export const shareIntent: ShareIntent = new ShareIntent();
