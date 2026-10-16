/*
 * ImageCache.ets — 把 Reader 正文里的远程图片内联为 base64 data URI，实现图片离线可读。
 *
 * 为什么内联而不落盘：Reader 文档是用 loadData（baseUrl 为 http 原文地址）加载的，
 * 页面若引用 file:// 沙箱图片会因跨源策略被拦；data URI 没有跨源问题，离线也稳定。
 * 代价是正文体积变大，因此有「单图 / 总量 / 张数」三重预算，超限的图片保留远程链接不缓存。
 */

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReaderConstants, RssConstants } from '../common/constants/RssConstants';
import { decodeEntities } from './RssParser';

const DOMAIN: number = 0x0000;
const TAG: string = 'ImageCache';

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

/** 由 URL 后缀猜 mime（拿不到响应头时的兜底）。 */
function guessMime(url: string): string {
  const lower: string = url.toLowerCase();
  if (lower.indexOf('.png') >= 0) {
    return 'image/png';
  }
  if (lower.indexOf('.gif') >= 0) {
    return 'image/gif';
  }
  if (lower.indexOf('.webp') >= 0) {
    return 'image/webp';
  }
  if (lower.indexOf('.svg') >= 0) {
    return 'image/svg+xml';
  }
  if (lower.indexOf('.avif') >= 0) {
    return 'image/avif';
  }
  return 'image/jpeg';
}

function asciiAt(bytes: Uint8Array, start: number, text: string): boolean {
  for (let i = 0; i < text.length; i += 1) {
    if (bytes[start + i] !== text.charCodeAt(i)) {
      return false;
    }
  }
  return true;
}

/**
 * 按文件魔数嗅探真实 mime。
 * 必须嗅探而不能只看 URL：很多站点返回 AVIF/WebP（URL 无扩展名），
 * 若 data URI 的 mime 与实际内容不符，浏览器解码会失败（破图）。
 */
function sniffMime(bytes: Uint8Array, url: string): string {
  if (bytes.length >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 6 && asciiAt(bytes, 0, 'GIF')) {
    return 'image/gif';
  }
  if (bytes.length >= 12 && asciiAt(bytes, 0, 'RIFF') && asciiAt(bytes, 8, 'WEBP')) {
    return 'image/webp';
  }
  if (bytes.length >= 12 && asciiAt(bytes, 4, 'ftyp')) {
    if (asciiAt(bytes, 8, 'heic') || asciiAt(bytes, 8, 'heix') || asciiAt(bytes, 8, 'mif1')) {
      return 'image/heic';
    }
    return 'image/avif';
  }
  return guessMime(url);
}

export class ImageCache {
  /** 下载单张图片并编码为 data URI；失败返回空串。 */
  private async download(url: string): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    const header: Record<string, string> = { 'Accept': 'image/*' };
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: RssConstants.CONNECT_TIMEOUT_MS,
        readTimeout: RssConstants.READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: header
      };
      const response: http.HttpResponse = await request.request(url, options);
      if (response.responseCode !== http.ResponseCode.OK) {
        return '';
      }
      const result: string | Object | ArrayBuffer = response.result;
      if (!(result instanceof ArrayBuffer)) {
        return '';
      }
      const bytes: Uint8Array = new Uint8Array(result);
      const base64: string = new util.Base64Helper().encodeToStringSync(bytes);
      return 'data:' + sniffMime(bytes, url) + ';base64,' + base64;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'download failed: %{public}d', error.code);
      return '';
    } finally {
      request.destroy();
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
