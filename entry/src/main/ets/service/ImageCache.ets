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
import { verifiedImageMime } from './MimeSniff';
import { ImageDownscale } from './ImageDownscale';
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

/** 图片补全结果：仍需联网的张数，以及其中可在下次打开时重试的张数。 */
export class InlineImagesResult {
  readonly html: string;
  readonly remainingRemote: number;
  readonly retryable: number;
  readonly inlined: number;

  constructor(html: string, remainingRemote: number, retryable: number, inlined: number) {
    this.html = html;
    this.remainingRemote = remainingRemote;
    this.retryable = retryable;
    this.inlined = inlined;
  }
}

class InlineTagResult {
  readonly tag: string;
  readonly remainingRemote: number;
  readonly retryable: number;

  constructor(tag: string, remainingRemote: number, retryable: number) {
    this.tag = tag;
    this.remainingRemote = remainingRemote;
    this.retryable = retryable;
  }
}

class ImageDownloadResult {
  readonly dataUri: string;
  readonly retryable: boolean;

  constructor(dataUri: string, retryable: boolean) {
    this.dataUri = dataUri;
    this.retryable = retryable;
  }
}

export class ImageCache {
  /** 下载单张图片并编码为 data URI；无法识别的内容永久跳过，网络失败可重试。 */
  private async download(url: string): Promise<ImageDownloadResult> {
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
        return new ImageDownloadResult('', true);
      }
      const bytes: Uint8Array = response.bytes;
      const mime: string = verifiedImageMime(bytes);
      if (mime.length === 0) {
        hilog.warn(DOMAIN, TAG, 'image response has no supported signature');
        return new ImageDownloadResult('', false);
      }
      // 大 JPEG 先缩边+重编码，显著缩小 base64 体积（首屏解析与本地库都受益）。
      const payload: Uint8Array = await ImageDownscale.shrinkIfWorthWhile(bytes, mime);
      const base64: string = new util.Base64Helper().encodeToStringSync(payload);
      return new ImageDownloadResult('data:' + mime + ';base64,' + base64, false);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'download failed: %{public}d', error.code);
      return new ImageDownloadResult('', true);
    }
  }

  /**
   * 遍历正文片段里的 <img>，把可缓存的远程图片替换为 data URI。
   * 相对图片在净化阶段已绝对化；这里仅处理 http/https。
   */
  async inlineImages(fragment: string): Promise<InlineImagesResult> {
    const parts: string[] = [];
    let cursor: number = 0;
    let count: number = 0;
    let budget: number = ReaderConstants.MAX_INLINE_TOTAL_CHARS;
    let remainingRemote: number = 0;
    let retryable: number = 0;

    while (cursor < fragment.length) {
      const start: number = fragment.indexOf('<img', cursor);
      if (start < 0) {
        parts.push(fragment.substring(cursor));
        break;
      }
      parts.push(fragment.substring(cursor, start));
      const end: number = fragment.indexOf('>', start);
      if (end < 0) {
        parts.push(fragment.substring(start));
        break;
      }
      const tag: string = fragment.substring(start, end + 1);
      const src: string = decodeEntities(extractSrc(tag));
      if (src.toLowerCase().startsWith('data:image/')) {
        count++;
        budget -= src.length;
      }
      const result: InlineTagResult = await this.maybeInlineTag(tag, count, budget, (used: number) => {
        budget -= used;
        count += 1;
      });
      parts.push(result.tag);
      remainingRemote += result.remainingRemote;
      retryable += result.retryable;
      cursor = end + 1;
    }
    hilog.info(DOMAIN, TAG, 'inlineImages: cached=%{public}d pending=%{public}d retry=%{public}d',
      count, remainingRemote, retryable);
    return new InlineImagesResult(parts.join(''), remainingRemote, retryable, count);
  }

  /** 处理单个 <img> 标签：可缓存则返回替换后的标签，否则原样返回。 */
  private async maybeInlineTag(tag: string, count: number, budget: number,
    onInlined: (usedChars: number) => void): Promise<InlineTagResult> {
    const rawSrc: string = extractSrc(tag);
    if (rawSrc.length === 0) {
      return new InlineTagResult(tag, 0, 0);
    }
    const src: string = decodeEntities(rawSrc);
    const lower: string = src.toLowerCase();
    const isRemote: boolean = lower.startsWith('http://') || lower.startsWith('https://');
    if (!isRemote) {
      return new InlineTagResult(tag, 0, 0);
    }
    if (count >= ReaderConstants.MAX_INLINE_IMAGES || budget <= 0) {
      return new InlineTagResult(tag, 1, 0);
    }
    const downloaded: ImageDownloadResult = await this.download(src);
    const dataUri: string = downloaded.dataUri;
    if (dataUri.length === 0) {
      return new InlineTagResult(tag, 1, downloaded.retryable ? 1 : 0);
    }
    if (dataUri.length > ReaderConstants.MAX_INLINE_IMAGE_CHARS || dataUri.length > budget) {
      return new InlineTagResult(tag, 1, 0);
    }
    onInlined(dataUri.length);
    return new InlineTagResult(tag.split('src="' + rawSrc + '"').join('src="' + dataUri + '"'), 0, 0);
  }
}

/** 全局唯一实例。 */
export const imageCache: ImageCache = new ImageCache();
