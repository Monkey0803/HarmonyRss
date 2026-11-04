/* User cloud-space backup file adapter. */
import { fileIo } from '@kit.CoreFileKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { RssConstants } from '../common/constants/RssConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'CloudBackupFiles';

/** 云空间备份不可用的原因；页面据此显示准确文案。 */
export enum CloudBackupReason {
  /** 可用。 */
  NONE = 'none',
  /** 应用清单未开启端云文件同步能力（cloudFileSyncEnabled）。 */
  NOT_CONFIGURED = 'notConfigured',
  /** 能力已开启，但云目录不可用：不可创建 / 不可写（未登录华为账号 / 未开通云空间 / 系统或云空间版本过低）。 */
  NOT_PROVISIONED = 'notProvisioned',
  /** 其他文件访问异常。 */
  IO_ERROR = 'ioError'
}

function logFailure(action: string, err: Object): void {
  const detail: string = err instanceof Error ? err.message : 'unknown error';
  hilog.error(DOMAIN, TAG, '%{public}s failed: %{public}s', action, detail);
}

/** 写一条带路径与错误码的诊断日志：真机排查云目录时直接看得到原因。 */
function logDirFailure(action: string, dir: string, err: Object): void {
  const error: BusinessError = err as BusinessError;
  const code: number = typeof error.code === 'number' ? error.code : 0;
  const detail: string = typeof error.message === 'string' ? error.message : 'unknown error';
  hilog.error(DOMAIN, TAG, '%{public}s failed: dir=%{public}s code=%{public}d message=%{public}s',
    action, dir, code, detail);
}

/** 目录创建失败折算成页面可解释的原因：权限类视为云空间未开通，其余按 IO 异常。 */
function reasonOfDirError(err: Object): CloudBackupReason {
  const error: BusinessError = err as BusinessError;
  const code: number = typeof error.code === 'number' ? error.code : 0;
  if (code === 13900001 || code === 13900012 || code === 201) {
    return CloudBackupReason.NOT_PROVISIONED;
  }
  return CloudBackupReason.IO_ERROR;
}

// ---- 端云文件协同（用户云空间） ----

/** 云空间备份的状态快照（页面展示用）。 */
export class CloudBackupInfo {
  /** 云文件目录是否可用。 */
  readonly available: boolean;
  /** 是否已经有备份文件。 */
  readonly exists: boolean;
  /** 备份文件最后修改时间（毫秒）；0 表示不存在。 */
  readonly at: number;
  /** 字节数；0 表示不存在。 */
  readonly bytes: number;
  /** 不可用时的原因（available 为 true 时恒为 NONE）。 */
  readonly reason: CloudBackupReason;

  constructor(available: boolean, exists: boolean, at: number, bytes: number,
    reason: CloudBackupReason) {
    this.available = available;
    this.exists = exists;
    this.at = at;
    this.bytes = bytes;
    this.reason = reason;
  }
}

/** 应用清单是否开启端云文件同步（cloudFileSyncEnabled，默认 false）。 */
function cloudFileSyncEnabled(): boolean {
  try {
    const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    return info.appInfo.cloudFileSyncEnabled === true;
  } catch (err) {
    logFailure('cloudFileSyncEnabled', err as Object);
    return false;
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
  if (!cloudFileSyncEnabled()) {
    hilog.warn(DOMAIN, TAG, 'cloud dir skipped: cloudFileSyncEnabled is false');
    return '';
  }
  try {
    if (fileIo.accessSync(dir)) {
      return dir;
    }
    fileIo.mkdirSync(dir, true);
    return dir;
  } catch (err) {
    logDirFailure('ensureCloudDir', dir, err as Object);
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
 * 判定顺序：
 *   1) 清单是否开启 cloudFileSyncEnabled（默认 false，漏配时系统不会准备云目录）；
 *   2) 云目录不存在时尝试创建一次；创建成功后再校验写权限（建目录成功不代表可写）；
 *   3) 目录 / 文件操作失败按错误码区分「云空间未开通 / 账号未登录」和普通 IO 异常。
 */
export function cloudBackupInfo(context: common.Context,
  fileName: string = RssConstants.CLOUD_BACKUP_FILE): CloudBackupInfo {
  const dir: string = context.cloudFileDir;
  if (typeof dir !== 'string' || dir.length === 0) {
    hilog.warn(DOMAIN, TAG, 'cloud dir unavailable: context.cloudFileDir is empty');
    return new CloudBackupInfo(false, false, 0, 0, CloudBackupReason.NOT_CONFIGURED);
  }
  if (!cloudFileSyncEnabled()) {
    hilog.warn(DOMAIN, TAG, 'cloud dir unavailable: cloudFileSyncEnabled is false in app.json5');
    return new CloudBackupInfo(false, false, 0, 0, CloudBackupReason.NOT_CONFIGURED);
  }
  const path: string = dir + '/' + fileName;
  try {
    if (!fileIo.accessSync(dir)) {
      try {
        fileIo.mkdirSync(dir, true);
        hilog.info(DOMAIN, TAG, 'cloud dir created: %{public}s', dir);
      } catch (mkdirErr) {
        logDirFailure('cloudBackupInfo.mkdir', dir, mkdirErr as Object);
        return new CloudBackupInfo(false, false, 0, 0, reasonOfDirError(mkdirErr as Object));
      }
    }
    // 目录存在不代表可写：模拟器 / 未开通云空间的设备可能只允许建目录。
    // accessSync 在部分系统上会直接抛 Permission denied，先兜住再按原因归类。
    let writable: boolean = false;
    try {
      writable = fileIo.accessSync(dir, fileIo.AccessModeType.WRITE);
    } catch (accessErr) {
      logDirFailure('cloudBackupInfo.access', dir, accessErr as Object);
      return new CloudBackupInfo(false, false, 0, 0, reasonOfDirError(accessErr as Object));
    }
    if (!writable) {
      hilog.warn(DOMAIN, TAG, 'cloud dir is not writable: %{public}s', dir);
      return new CloudBackupInfo(false, false, 0, 0, CloudBackupReason.NOT_PROVISIONED);
    }
    if (!fileIo.accessSync(path)) {
      return new CloudBackupInfo(true, false, 0, 0, CloudBackupReason.NONE);
    }
    const stat: fileIo.Stat = fileIo.statSync(path);
    const at: number = typeof stat.mtime === 'number' ? stat.mtime * 1000 : 0;
    return new CloudBackupInfo(true, true, at, stat.size, CloudBackupReason.NONE);
  } catch (err) {
    logDirFailure('cloudBackupInfo', dir, err as Object);
    return new CloudBackupInfo(false, false, 0, 0, CloudBackupReason.IO_ERROR);
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
    logDirFailure('writeCloudBackup', path, err as Object);
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
