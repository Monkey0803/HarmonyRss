/*
 * ReaderImageSave.ets — 把正文图片保存到系统相册。
 *
 * 图片来源有两种：离线内联的 data URI（base64）与远程 http(s) 链接。
 * 保存走安全控件（SaveButton）拿到的一次性媒体库授权，因此本类不再申请相册权限。
 */

import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RssConstants } from '../common/constants/RssConstants';
import { sniffMime } from './MimeSniff';
import { HttpOptions, HttpResponse, httpClient } from './HttpClient';

const DOMAIN: number = 0x0000;
const TAG: string = 'ReaderImageSave';

/** mime → 相册资源的扩展名。 */
function extensionOf(mime: string): string {
  if (mime.indexOf('png') >= 0) {
    return 'png';
  }
  if (mime.indexOf('webp') >= 0) {
    return 'webp';
  }
  if (mime.indexOf('gif') >= 0) {
    return 'gif';
  }
  if (mime.indexOf('avif') >= 0) {
    return 'avif';
  }
  if (mime.indexOf('svg') >= 0) {
    return 'svg';
  }
  return 'jpg';
}

/** data URI → 字节；非 base64 的 data URI 返回空数组。 */
function decodeDataUri(src: string): Uint8Array {
  try {
    const comma: number = src.indexOf(',');
    if (comma < 0) {
      return new Uint8Array(0);
    }
    const meta: string = src.substring(0, comma).toLowerCase();
    if (meta.indexOf(';base64') < 0) {
      return new Uint8Array(0);
    }
    const payload: string = src.substring(comma + 1);
    return new util.Base64Helper().decodeSync(payload);
  } catch (err) {
    const error: BusinessError = err as BusinessError;
    hilog.warn(DOMAIN, TAG, 'decode data uri failed: %{public}d', error.code);
    return new Uint8Array(0);
  }
}

export class ReaderImageSave {
  /**
   * 保存一张图片到相册；失败返回 false（调用方给即时提示）。
   * @param referer 文章地址：部分站点校验图片防盗链，带上更稳。
   */
  async save(context: common.Context, src: string, referer: string): Promise<boolean> {
    const bytes: Uint8Array = await this.bytesOf(src, referer);
    if (bytes.length === 0) {
      return false;
    }
    const ext: string = extensionOf(sniffMime(bytes, src));
    try {
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      const uri: string = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, ext);
      const file: fileIo.File = await fileIo.open(uri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      try {
        await fileIo.write(file.fd, bytes.buffer);
      } finally {
        await fileIo.close(file.fd);
      }
      hilog.info(DOMAIN, TAG, 'image saved (%{public}d bytes)', bytes.length);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'save image failed: %{public}d', error.code);
      return false;
    }
  }

  /**
   * 远程图片 → data URI。
   * ArkUI 的 Image 直接加载远程地址不带 Referer，很多站点（如 SSPAI 的 CDN）会拒绝；
   * 这里复用下载逻辑（带 Referer / 超时 / 失败兜底）再交给 Image 显示。
   */
  async toDataUri(src: string, referer: string): Promise<string> {
    if (src.startsWith('data:')) {
      return src;
    }
    const bytes: Uint8Array = await this.bytesOf(src, referer);
    if (bytes.length === 0) {
      return '';
    }
    try {
      const base64: string = new util.Base64Helper().encodeToStringSync(bytes);
      return 'data:' + sniffMime(bytes, src) + ';base64,' + base64;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'encode viewer image failed: %{public}d', error.code);
      return '';
    }
  }

  /** data URI 直接解码；远程图片下载字节。 */
  private async bytesOf(src: string, referer: string): Promise<Uint8Array> {
    if (src.startsWith('data:')) {
      return decodeDataUri(src);
    }
    const lower: string = src.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return new Uint8Array(0);
    }
    try {
      const header: Record<string, string> = { 'Accept': 'image/*' };
      if (referer.length > 0) {
        header['Referer'] = referer;
      }
      const options: HttpOptions = new HttpOptions();
      options.headers = header;
      options.binary = true;
      options.connectTimeoutMs = RssConstants.CONNECT_TIMEOUT_MS;
      options.readTimeoutMs = RssConstants.READ_TIMEOUT_MS;
      const response: HttpResponse = await httpClient.getBytes(src, options);
      if (response.status !== 200 || response.bytes === undefined) {
        return new Uint8Array(0);
      }
      return response.bytes;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'download image failed: %{public}d', error.code);
      return new Uint8Array(0);
    }
  }
}

/** 全局唯一实例。 */
export const readerImageSave: ReaderImageSave = new ReaderImageSave();
