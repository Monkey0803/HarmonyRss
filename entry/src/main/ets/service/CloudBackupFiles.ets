/* User cloud-space backup file adapter. */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RssConstants } from '../common/constants/RssConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'CloudBackupFiles';

function logFailure(action: string, err: Object): void {
  const detail: string = err instanceof Error ? err.message : 'unknown error';
  hilog.error(DOMAIN, TAG, '%{public}s failed: %{public}s', action, detail);
}

// ---- 端云文件协同（用户云空间） ----

/** 云空间备份的状态快照（页面展示用）。 */
export class CloudBackupInfo {
  /** 云文件目录是否可用（系统版本过低 / 无云空间时为 false）。 */
  readonly available: boolean;
  /** 是否已经有备份文件。 */
  readonly exists: boolean;
  /** 备份文件最后修改时间（毫秒）；0 表示不存在。 */
  readonly at: number;
  /** 字节数；0 表示不存在。 */
  readonly bytes: number;

  constructor(available: boolean, exists: boolean, at: number, bytes: number) {
    this.available = available;
    this.exists = exists;
    this.at = at;
    this.bytes = bytes;
  }
}

/**
 * 确保云目录存在并返回它；系统 / 云空间不支持时返回空串。
 *
 * `cloudFileDir` 只是路径：目录本身要等「首次写入」时才创建（旧系统或未开通云空间时不会存在），
 * 因此这里按需 mkdir；目录创建成功后系统同样会自动触发端云同步。
 */
function ensureCloudDir(context: common.Context): string {
  const dir: string = context.cloudFileDir;
  if (typeof dir !== 'string' || dir.length === 0) {
    return '';
  }
  try {
    if (fileIo.accessSync(dir)) {
      return dir;
    }
    fileIo.mkdirSync(dir, true);
    return dir;
  } catch (err) {
    logFailure('ensureCloudDir', err as Object);
    return '';
  }
}

/** 云空间备份文件路径；云目录不可用时返回空串（读路径不创建目录）。 */
function cloudFileOf(context: common.Context,
  fileName: string = RssConstants.CLOUD_BACKUP_FILE): string {
  const dir: string = context.cloudFileDir;
  if (typeof dir !== 'string' || dir.length === 0) {
    return '';
  }
  return dir + '/' + fileName;
}

/**
 * 读云空间备份状态；任何异常都按「不可用 / 不存在」处理，不抛给 UI。
 *
 * 可用性以「云目录是否存在」为准：支持的设备上系统会预建 el2/cloud；
 * 目录缺失通常意味着未登录华为账号 / 未开通云空间 / 系统版本过低，此时页面只展示说明、不提供按钮。
 */
export function cloudBackupInfo(context: common.Context,
  fileName: string = RssConstants.CLOUD_BACKUP_FILE): CloudBackupInfo {
  const path: string = cloudFileOf(context, fileName);
  const dir: string = context.cloudFileDir;
  if (path.length === 0 || typeof dir !== 'string' || dir.length === 0) {
    return new CloudBackupInfo(false, false, 0, 0);
  }
  try {
    if (!fileIo.accessSync(dir)) {
      return new CloudBackupInfo(false, false, 0, 0);
    }
    if (!fileIo.accessSync(path)) {
      return new CloudBackupInfo(true, false, 0, 0);
    }
    const stat: fileIo.Stat = fileIo.statSync(path);
    const at: number = typeof stat.mtime === 'number' ? stat.mtime * 1000 : 0;
    return new CloudBackupInfo(true, true, at, stat.size);
  } catch (err) {
    logFailure('cloudBackupInfo', err as Object);
    return new CloudBackupInfo(false, false, 0, 0);
  }
}

/**
 * 把备份写进用户云空间（固定文件名，只保留最新一份）。
 * 写入成功后系统自动触发端云同步；返回是否写成功。
 */
export function writeCloudBackup(context: common.Context, content: string,
  fileName: string = RssConstants.CLOUD_BACKUP_FILE): boolean {
  if (ensureCloudDir(context).length === 0) {
    return false;
  }
  const path: string = cloudFileOf(context, fileName);
  if (path.length === 0 || content.length === 0) {
    return false;
  }
  try {
    const file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, content);
    } finally {
      fileIo.closeSync(file);
    }
    return true;
  } catch (err) {
    logFailure('writeCloudBackup', err as Object);
    return false;
  }
}

/** 读云空间备份文本；不存在 / 读取失败返回空串。 */
export function readCloudBackup(context: common.Context,
  fileName: string = RssConstants.CLOUD_BACKUP_FILE): string {
  const path: string = cloudFileOf(context, fileName);
  if (path.length === 0) {
    return '';
  }
  try {
    if (!fileIo.accessSync(path)) {
      return '';
    }
    const stat: fileIo.Stat = fileIo.statSync(path);
    if (stat.size <= 0) {
      return '';
    }
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const read: number = fileIo.readSync(file.fd, buffer);
      if (read <= 0) {
        return '';
      }
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer.slice(0, read)));
    } finally {
      fileIo.closeSync(file);
    }
  } catch (err) {
    logFailure('readCloudBackup', err as Object);
    return '';
  }
}
