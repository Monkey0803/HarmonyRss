/*
 * BackgroundImageService.ets — 从系统图库选择一张图片作为全局背景（Model 层）。
 *
 * 图库选择器（PhotoViewPicker）由系统提供，不需要申请读媒体权限；选中的 URI 只在本次会话内
 * 由选择器临时授权，因此这里立刻把图片复制到应用沙箱，之后用稳定的沙箱路径渲染背景。
 * 沙箱路径是纯逻辑字符串，落盘在偏好库里；渲染时用 fileUri 转成 Image 可用的 file:// URI。
 */

import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'BackgroundImageService';

/** 沙箱内的固定文件名：每次重新选择都覆盖它，避免沙箱堆积。 */
const FILE_NAME: string = 'global_background';

export class BackgroundImageService {
  /**
   * 打开系统图库选择器（只允许图片、最多 1 张）。
   * 返回复制到沙箱后的文件路径；用户取消或失败时返回空串。
   */
  async pick(context: common.Context): Promise<string> {
    try {
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (result.photoUris.length === 0) {
        return '';
      }
      return this.copyToSandbox(context, result.photoUris[0]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'pick failed: %{public}d', error.code);
      return '';
    }
  }

  /** 沙箱文件路径转 Image 组件可直接使用的 file:// URI。 */
  toImageSource(path: string): string {
    if (path.length === 0) {
      return '';
    }
    try {
      return fileUri.getUriFromPath(path);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'getUriFromPath failed: %{public}d', error.code);
      return '';
    }
  }

  /** 沙箱内已保存的背景图是否仍然存在。 */
  exists(path: string): boolean {
    if (path.length === 0) {
      return false;
    }
    try {
      return fileIo.accessSync(path);
    } catch (err) {
      return false;
    }
  }

  /** 关闭句柄失败只记日志，不能覆盖真正的业务错误。 */
  private closeQuietly(file: fileIo.File): void {
    try {
      fileIo.closeSync(file);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'close failed: %{public}d', error.code);
    }
  }

  /**
   * 把选中的图片复制进沙箱。文件 IO 全程可能抛异常，统一 catch 后返回空串表示失败
   * （调用方按「空路径 = 失败」处理）。
   */
  private copyToSandbox(context: common.Context, uri: string): string {
    const target: string = context.filesDir + '/' + FILE_NAME;
    try {
      const source: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      try {
        const destination: fileIo.File = fileIo.openSync(target,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          fileIo.copyFileSync(source.fd, destination.fd);
        } finally {
          this.closeQuietly(destination);
        }
      } finally {
        this.closeQuietly(source);
      }
      return target;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'copyToSandbox failed: %{public}d', error.code);
      return '';
    }
  }
}

/** 全局唯一实例。 */
export const backgroundImageService: BackgroundImageService = new BackgroundImageService();
