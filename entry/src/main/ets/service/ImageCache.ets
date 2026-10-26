/*
 * ImageCache.ets — 把 Reader 正文里的远程图片内联为 base64 data URI，实现图片离线可读。
 *
 * 为什么内联而不落盘：Reader 文档是用 loadData（baseUrl 为 http 原文地址）加载的，
 * 页面若引用 file:// 沙箱图片会因跨源策略被拦；data URI 没有跨源问题，离线也稳定。
 * 代价是正文体积变大，因此有「单图 / 总量 / 张数」三重预算，超限的图片保留远程链接不缓存。
 */

import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReaderConstants, RssConstants } from '../common/constants/RssConstants';
import { decodeEntities } from './RssParser';
import { sniffMime } from './MimeSniff';
import { HttpOptions, HttpResponse, httpClient } from './HttpClient';

const DOMAIN: number = 0x0000;
const TAG: string = 'ImageCache';
/** 同一主机两次图片请求的最小间隔（毫秒）。 */
const IMAGE_HOST_INTERVAL_MS: number = 80;

/** 从 <img ...> 标签文本里取出 src 的值（返回转义后的原样，未解码）。 */
function extractSrc(tag: string): string {
  const key: string = 'src="';
  const start: number = tag.indexOf(key);
  if (start < 0) {
    return '';
  }
  const valueStart: number = start + key.length;
  const end: number = tag.indexOf('"', valueStart);
  if (end < 0) {
    return '';
  }
  return tag.substring(valueStart, end);
}

export class ImageCache {
  /** 下载单张图片并编码为 data URI；失败返回空串。 */
  private async download(url: string): Promise<string> {
    const header: Record<string, string> = { 'Accept': 'image/*' };
    const options: HttpOptions = new HttpOptions();
    options.headers = header;
    options.binary = true;
    options.connectTimeoutMs = RssConstants.CONNECT_TIMEOUT_MS;
    options.readTimeoutMs = RssConstants.READ_TIMEOUT_MS;
    // 图片是次要资源：同一主机轻微限流，避免正文里几十张图同时打爆站点。
    options.minIntervalMs = IMAGE_HOST_INTERVAL_MS;
    try {
      const response: HttpResponse = await httpClient.getBytes(url, options);
      if (response.status !== 200 || response.bytes === undefined || response.bytes.length === 0) {
        return '';
      }
      const bytes: Uint8Array = response.bytes;
      const base64: string = new util.Base64Helper().encodeToStringSync(bytes);
      return 'data:' + sniffMime(bytes, url) + ';base64,' + base64;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'download failed: %{public}d', error.code);
      return '';
    }
  }

  /**
   * 遍历正文片段里的 <img>，把可缓存的远程图片替换为 data URI。
   * baseUrl 仅用于解析相对地址（相对图片在净化阶段已绝对化，这里只处理 http/https）。
   */
  async inlineImages(fragment: string, baseUrl: string): Promise<string> {
    let out: string = '';
    let cursor: number = 0;
    let count: number = 0;
    let budget: number = ReaderConstants.MAX_INLINE_TOTAL_CHARS;

    while (cursor < fragment.length) {
      const start: number = fragment.indexOf('<img', cursor);
      if (start < 0) {
        out += fragment.substring(cursor);
        break;
      }
      out += fragment.substring(cursor, start);
      const end: number = fragment.indexOf('>', start);
      if (end < 0) {
        out += fragment.substring(start);
        break;
      }
      const tag: string = fragment.substring(start, end + 1);
      out += await this.maybeInlineTag(tag, baseUrl, count, budget, (used: number) => {
        budget -= used;
        count += 1;
      });
      cursor = end + 1;
    }
    hilog.info(DOMAIN, TAG, 'inlineImages: inlined=%{public}d of %{public}d chars',
      count, fragment.length);
    return out;
  }

  /** 处理单个 <img> 标签：可缓存则返回替换后的标签，否则原样返回。 */
  private async maybeInlineTag(tag: string, baseUrl: string, count: number, budget: number,
    onInlined: (usedChars: number) => void): Promise<string> {
    const rawSrc: string = extractSrc(tag);
    if (rawSrc.length === 0) {
      return tag;
    }
    const src: string = decodeEntities(rawSrc);
    const lower: string = src.toLowerCase();
    const isRemote: boolean = lower.startsWith('http://') || lower.startsWith('https://');
    if (!isRemote || count >= ReaderConstants.MAX_INLINE_IMAGES || budget <= 0) {
      return tag;
    }
    const dataUri: string = await this.download(src);
    if (dataUri.length === 0 || dataUri.length > ReaderConstants.MAX_INLINE_IMAGE_CHARS
      || dataUri.length > budget) {
      return tag;
    }
    onInlined(dataUri.length);
    return tag.split('src="' + rawSrc + '"').join('src="' + dataUri + '"');
  }
}

/** 全局唯一实例。 */
export const imageCache: ImageCache = new ImageCache();
