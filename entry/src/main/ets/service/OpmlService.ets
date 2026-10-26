/*
 * OpmlService.ets — OPML 文件读写（Model 层：系统文件选择器 + 文件 IO）。
 *
 * 导入 / 导出都走系统文档选择器（DocumentViewPicker），用户自己挑位置，不需要申请存储权限。
 * 导出：选择器给出目标 URI → 直接写入；导入：选择器给出源 URI → 读成字符串交给 codec 解析。
 */

import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { OpmlConstants } from '../common/constants/RssConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'OpmlService';

export class OpmlService {
  /** 让用户选一个位置保存 OPML；成功返回 true，取消返回 false。 */
  async exportToFile(context: common.Context, content: string): Promise<boolean> {
    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [OpmlConstants.FILE_NAME];
      options.fileSuffixChoices = [OpmlConstants.FILE_SUFFIX_FILTER];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: Array<string> = await documentPicker.save(options);
      if (uris.length === 0) {
        return false;
      }
      return this.writeText(uris[0], content);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'export failed: %{public}d', error.code);
      return false;
    }
  }

  /** 让用户选一个 OPML 文件并读出内容；取消或失败返回空串。 */
  async importFromFile(context: common.Context): Promise<string> {
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = [OpmlConstants.FILE_SUFFIX_FILTER];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: Array<string> = await documentPicker.select(options);
      if (uris.length === 0) {
        return '';
      }
      return this.readText(uris[0]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'import failed: %{public}d', error.code);
      return '';
    }
  }

  /**
   * 把内容写进目标 URI。文件 IO 全部可能抛异常，统一在这里 catch：
   * ArkTS 要求「可能抛异常的调用」必须被 catch 处理（只有 finally 不算）。
   */
  private writeText(uri: string, content: string): boolean {
    try {
      const file: fileIo.File = fileIo.openSync(uri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, content);
        return true;
      } finally {
        this.closeQuietly(file);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'write failed: %{public}d', error.code);
      return false;
    }
  }

  /** 关闭文件句柄；关闭失败也不能覆盖真正的业务错误，只记日志。 */
  private closeQuietly(file: fileIo.File): void {
    try {
      fileIo.closeSync(file);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'close failed: %{public}d', error.code);
    }
  }

  /**
   * 读文本：选择器返回的是 `file://docs/...` 这类 URI，`readTextSync` 只认沙箱路径，
   * 直接传 URI 会报 "No such file or directory"。必须先 open 拿到 fd 再按字节读。
   */
  private readText(uri: string): string {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(file.fd).size;
      if (size > 0) {
        const buffer: ArrayBuffer = new ArrayBuffer(size);
        const readLen: number = fileIo.readSync(file.fd, buffer);
        if (readLen > 0) {
          const bytes: Uint8Array = new Uint8Array(buffer, 0, readLen);
          return util.TextDecoder.create('utf-8').decodeToString(bytes);
        }
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'read failed: %{public}d', error.code);
    } finally {
      if (file !== undefined) {
        this.closeQuietly(file);
      }
    }
    // 兜底：沙箱内路径仍走 readTextSync。
    try {
      return fileIo.readTextSync(uri, { encoding: 'utf-8' });
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'read failed: %{public}d', error.code);
      return '';
    }
  }
}

/** 全局唯一实例。 */
export const opmlService: OpmlService = new OpmlService();
