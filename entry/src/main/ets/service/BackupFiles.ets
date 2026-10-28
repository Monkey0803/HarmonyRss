/*
 * BackupFiles.ets — 备份快照的私有目录读写（纯文件层，不解析内容）。
 *
 * 快照统一放在 `context.filesDir/backups/`：应用私有目录，无需存储权限，也不暴露给文件管理器。
 * 文件 IO 全部 try/catch：失败时返回空串 / false / 空数组，绝不把异常抛给 UI 编排层。
 * 按文件名（内含 yyyyMMdd）倒序即为「新 → 旧」，清理只依赖这个稳定顺序。
 */

import { fileIo, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RssConstants } from '../common/constants/RssConstants';
import { SnapshotInfo } from '../model/Backup';

const DOMAIN: number = 0x0000;
const TAG: string = 'BackupFiles';
/** 备份文件后缀：快照与用户导出的文件一致，均为 JSON。 */
const FILE_SUFFIX: string = '.json';

/**
 * 日志统一走 hiLog。
 * 取消选择器 / JSON 解析等异常并不是 BusinessError，没有 code 字段；只读 message 才不会二次崩溃。
 */
function logFailure(action: string, err: Object): void {
  const detail: string = err instanceof Error ? err.message : 'unknown error';
  hilog.error(DOMAIN, TAG, '%{public}s failed: %{public}s', action, detail);
}

/** 两位补零（月份 / 日期）。 */
function pad2(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

/**
 * 选择器 / 写文件的三种结局。
 * 单独拆出来是为了让 UI 能区分「用户自己取消」与「真的失败」：
 * 取消不该弹错误提示，失败必须说明原因（见 BackupViewModel.lastCancelled）。
 */
export enum PickerStatus {
  DONE = 0,
  CANCELLED = 1,
  FAILED = 2
}

/** 选择器输出：status 决定提示文案，text 只被导入链路使用。 */
export class PickerOutput {
  status: PickerStatus;
  text: string;

  constructor(status: PickerStatus = PickerStatus.FAILED, text: string = '') {
    this.status = status;
    this.text = text;
  }
}

/**
 * 备份文件名：`harmonyrss-backup-YYYYMMDD.json`（纯函数）。
 * 文件名内含日期 → 字典序即时间序（列表与清理都依赖这一点），同一天重复生成天然覆盖。
 */
export function backupFileName(date: Date): string {
  const stamp: string = date.getFullYear().toString() + pad2(date.getMonth() + 1) +
    pad2(date.getDate());
  return RssConstants.BACKUP_FILE_PREFIX + stamp + FILE_SUFFIX;
}

/**
 * 只保留文件名本身：防止调用方传入路径分隔符 / `..` 把快照写出目录。
 * 返回空串表示名称非法（调用方按失败处理）。
 */
function safeFileName(name: string): string {
  const trimmed: string = name.trim();
  if (trimmed.length === 0) {
    return '';
  }
  const replaced: string = trimmed.replace(/[\\/]/g, '-');
  if (replaced === '.' || replaced === '..') {
    return '';
  }
  return replaced;
}

/**
 * 确保快照目录存在，返回目录绝对路径；创建失败返回空串。
 * mkdirSync 的 recursion=true 使并发 / 已存在的情况幂等。
 */
export function ensureDir(context: common.Context): string {
  const dir: string = context.filesDir + '/' + RssConstants.BACKUP_SNAPSHOT_DIR;
  try {
    if (fileIo.accessSync(dir)) {
      return dir;
    }
    fileIo.mkdirSync(dir, true);
    return dir;
  } catch (err) {
    logFailure('ensureDir', err as Object);
    return '';
  }
}

/**
 * 写入一份快照，返回完整路径；失败返回空串。
 * 同名文件会被覆盖（同一天重复生成快照时天然去重）。
 */
export async function writeSnapshot(context: common.Context, name: string,
  content: string): Promise<string> {
  const fileName: string = safeFileName(name);
  if (fileName.length === 0) {
    return '';
  }
  const dir: string = ensureDir(context);
  if (dir.length === 0) {
    return '';
  }
  const path: string = dir + '/' + fileName;
  try {
    const file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, content);
      return path;
    } finally {
      closeQuietly(file);
    }
  } catch (err) {
    logFailure('writeSnapshot', err as Object);
    return '';
  }
}

/** 关闭句柄失败只记日志，不能覆盖真正的业务错误。 */
function closeQuietly(file: fileIo.File): void {
  try {
    fileIo.closeSync(file);
  } catch (err) {
    logFailure('close', err as Object);
  }
}

/**
 * 列出快照（只含 .json），按文件名倒序（新 → 旧）。
 * 单个文件 stat 失败只跳过该文件，不影响整张列表。
 */
export async function listSnapshots(context: common.Context): Promise<SnapshotInfo[]> {
  const result: SnapshotInfo[] = [];
  const dir: string = ensureDir(context);
  if (dir.length === 0) {
    return result;
  }
  let names: string[];
  try {
    names = await fileIo.listFile(dir);
  } catch (err) {
    logFailure('listSnapshots', err as Object);
    return result;
  }
  for (let i = 0; i < names.length; i += 1) {
    const fileName: string = names[i];
    if (!fileName.toLowerCase().endsWith(FILE_SUFFIX)) {
      continue;
    }
    const path: string = dir + '/' + fileName;
    try {
      const stat: fileIo.Stat = await fileIo.stat(path);
      // Stat.mtime 单位是秒；模型统一用毫秒。
      result.push(new SnapshotInfo(fileName, path, stat.size, Math.round(stat.mtime * 1000)));
    } catch (err) {
      logFailure('statSnapshot', err as Object);
      continue;
    }
  }
  result.sort((a: SnapshotInfo, b: SnapshotInfo): number => b.fileName.localeCompare(a.fileName));
  return result;
}

/** 读取快照文本；失败返回空串（由调用方判定为损坏 / 不可读）。 */
export async function readSnapshot(path: string): Promise<string> {
  if (path.length === 0) {
    return '';
  }
  return readText(path, 'readSnapshot');
}

/** 读文本（选择器 URI 与沙箱路径都要支持）。 */
function readText(uriOrPath: string, action: string): string {
  if (uriOrPath.length === 0) {
    return '';
  }
  // 选择器返回的是 `file://docs/...` 这类 URI，readTextSync 只认沙箱路径，
  // 直接传 URI 会报 "No such file or directory"。必须先 open 拿到 fd 再按字节读。
  let file: fileIo.File | undefined = undefined;
  try {
    file = fileIo.openSync(uriOrPath, fileIo.OpenMode.READ_ONLY);
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
    logFailure(action, err as Object);
  } finally {
    if (file !== undefined) {
      closeQuietly(file);
    }
  }
  // 兜底：沙箱内路径（快照）仍走 readTextSync，避免多一次 open/close。
  try {
    return fileIo.readTextSync(uriOrPath, { encoding: 'utf-8' });
  } catch (err) {
    logFailure(action, err as Object);
    return '';
  }
}

/** 把文本写进选择器给出的 URI；失败返回 false。 */
function writeText(uri: string, content: string): boolean {
  try {
    const file: fileIo.File = fileIo.openSync(uri,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, content);
      return true;
    } finally {
      closeQuietly(file);
    }
  } catch (err) {
    logFailure('writeText', err as Object);
    return false;
  }
}

/**
 * 让用户选位置保存备份 JSON（导出链路，见 OpmlService 同款 picker 写法）。
 * 返回 DONE / CANCELLED（用户取消保存面板）/ FAILED（写入失败或选择器异常）。
 * 写文件用 TRUNC：用户选中已有文件时按覆盖处理，避免尾部残留旧内容。
 */
export async function saveViaPicker(context: common.Context, content: string): Promise<PickerStatus> {
  try {
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [backupFileName(new Date())];
    options.fileSuffixChoices = [RssConstants.BACKUP_SUFFIX_FILTER];
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: Array<string> = await documentPicker.save(options);
    if (uris.length === 0) {
      return PickerStatus.CANCELLED;
    }
    return writeText(uris[0], content) ? PickerStatus.DONE : PickerStatus.FAILED;
  } catch (err) {
    logFailure('saveViaPicker', err as Object);
    return PickerStatus.FAILED;
  }
}

/**
 * 让用户选一个备份 JSON 并读出全文（导入链路）。
 * 拿到内容 → DONE；取消 → CANCELLED（不改任何数据）；读取失败 → FAILED。
 */
export async function selectViaPicker(context: common.Context): Promise<PickerOutput> {
  try {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = [RssConstants.BACKUP_SUFFIX_FILTER];
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: Array<string> = await documentPicker.select(options);
    if (uris.length === 0) {
      return new PickerOutput(PickerStatus.CANCELLED);
    }
    const text: string = readText(uris[0], 'selectViaPicker');
    if (text.length === 0) {
      return new PickerOutput(PickerStatus.FAILED);
    }
    return new PickerOutput(PickerStatus.DONE, text);
  } catch (err) {
    logFailure('selectViaPicker', err as Object);
    return new PickerOutput(PickerStatus.FAILED);
  }
}

/** 删除快照；成功 true，失败 / 路径为空 false。 */
export async function deleteSnapshot(path: string): Promise<boolean> {
  if (path.length === 0) {
    return false;
  }
  try {
    await fileIo.unlink(path);
    return true;
  } catch (err) {
    logFailure('deleteSnapshot', err as Object);
    return false;
  }
}

/**
 * 保留最近 keep 份，删除更旧的快照，返回实际删除数。
 * 顺序来自 listSnapshots（文件名倒序）；keep <= 0 时清空全部。
 */
export async function prune(context: common.Context, keep: number): Promise<number> {
  const limit: number = keep > 0 ? Math.floor(keep) : 0;
  const snapshots: SnapshotInfo[] = await listSnapshots(context);
  let removed: number = 0;
  for (let i = limit; i < snapshots.length; i += 1) {
    const deleted: boolean = await deleteSnapshot(snapshots[i].path);
    if (deleted) {
      removed += 1;
    }
  }
  return removed;
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
