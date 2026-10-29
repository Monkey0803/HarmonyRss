/*
 * ImageDownscale.ets — 正文内联前的图片压缩（保守策略：只处理大 JPEG）。
 *
 * 背景：正文图片以 base64 内联进 reader_html，既撑大本地库，也让 Web 首次解析变慢。
 * 做法：仅在「JPEG 且原图 > 200KB 且长边 > 1600px」时，按长边缩放到 1600 再以质量 70 重编码；
 * 只有明显变小（< 原图 85%）才采用，否则原样返回。任何异常都返回原图 —— 绝不因压缩丢图。
 *
 * 只处理 JPEG 是刻意的：PNG/WebP 可能带透明或动图，重编码容易出问题，收益也不稳定。
 */

import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ImageDownscale';
/** 触发压缩的最小原图体积（字节）。 */
const MIN_SOURCE_BYTES: number = 200 * 1024;
/** 缩放后的长边上限（px）。 */
const MAX_EDGE_PX: number = 1600;
/** 重编码质量。 */
const QUALITY: number = 70;
/** 结果必须小于原图的这个比例才采用，否则认为没有收益。 */
const KEEP_RATIO: number = 0.85;

export class ImageDownscale {
  /**
   * 视情况压缩；返回可安全用于 base64 内联的字节。
   * 失败 / 不划算 / 非 JPEG 时原样返回入参。
   */
  static async shrinkIfWorthWhile(bytes: Uint8Array, mime: string): Promise<Uint8Array> {
    if (!mime.startsWith('image/jpeg') || bytes.length <= MIN_SOURCE_BYTES) {
      return bytes;
    }
    let source: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    try {
      source = image.createImageSource(bytes.buffer);
      const info: image.ImageInfo = await source.getImageInfo();
      const longest: number = Math.max(info.size.width, info.size.height);
      if (longest <= MAX_EDGE_PX) {
        return bytes;
      }
      const scale: number = MAX_EDGE_PX / longest;
      const options: image.DecodingOptions = {
        desiredSize: {
          width: Math.max(1, Math.round(info.size.width * scale)),
          height: Math.max(1, Math.round(info.size.height * scale))
        }
      };
      pixelMap = await source.createPixelMap(options);
      packer = image.createImagePacker();
      const packed: ArrayBuffer = await packer.packToData(pixelMap, {
        format: 'image/jpeg',
        quality: QUALITY
      });
      if (packed.byteLength === 0 || packed.byteLength >= bytes.length * KEEP_RATIO) {
        return bytes;
      }
      hilog.info(DOMAIN, TAG, 'perf image=%{public}d->%{public}d',
        bytes.length, packed.byteLength);
      return new Uint8Array(packed);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'shrink failed: %{public}d', error.code);
      return bytes;
    } finally {
      await ImageDownscale.releaseAll(source, pixelMap, packer);
    }
  }

  /** 释放解码 / 编码资源；失败只记日志。 */
  private static async releaseAll(source: image.ImageSource | undefined,
    pixelMap: image.PixelMap | undefined, packer: image.ImagePacker | undefined): Promise<void> {
    if (pixelMap !== undefined) {
      try {
        await pixelMap.release();
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'release pixelmap failed: %{public}d', error.code);
      }
    }
    if (packer !== undefined) {
      try {
        await packer.release();
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'release packer failed: %{public}d', error.code);
      }
    }
    if (source !== undefined) {
      try {
        await source.release();
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'release source failed: %{public}d', error.code);
      }
    }
  }
}
