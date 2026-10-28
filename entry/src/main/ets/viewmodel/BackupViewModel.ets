/*
 * BackupViewModel.ets — 「备份与恢复」页的状态与编排（@ObservedV2）。
 *
 * 职责：把下面三件事的交互态收在这一层，页面只读状态、点按钮：
 *   - 导出 / 导入（含「同时恢复设置」开关）；
 *   - 手动快照 / 快照列表 / 恢复 / 删除；
 *   - 导入或恢复成功后刷新订阅列表与各计数。
 *
 * 真正的数据聚合与合并都在 BackupService（不反向依赖 ViewModel），
 * 这里只负责 busy 标记、结果统计、错误 key 与跨 ViewModel 的刷新顺序。
 */

import { common } from '@kit.AbilityKit';
import { BackupSummary, SnapshotInfo } from '../model/Backup';
import { BackupImportResult, BackupRunStatus, backupService } from '../service/BackupService';
import { CloudBackupInfo } from '../service/BackupFiles';
import { feedViewModel } from './FeedViewModel';
import { tagViewModel } from './TagViewModel';
import { ruleViewModel } from './RuleViewModel';
import { smartFolderViewModel } from './SmartFolderViewModel';

/** 备份页错误 key（空串 = 无错误；非空时由页面映射成 backup_* 文案）。 */
export class BackupError {
  static readonly NONE: string = '';
  /** 导出失败：写入失败或选择器异常（用户取消不算错误，见 lastCancelled）。 */
  static readonly EXPORT: string = 'backup_error_write';
  /** 导入失败：读取失败、JSON 损坏或版本不匹配（用户取消不算错误，见 lastCancelled）。 */
  static readonly IMPORT: string = 'backup_error_parse';
  /** 快照生成 / 恢复 / 删除失败。 */
  static readonly SNAPSHOT: string = 'backup_error_snapshot';
  /** 串行锁被占用（自动快照还在写）：什么都没做，提示稍后重试即可。 */
  static readonly BUSY: string = 'backup_error_busy';
}

@ObservedV2
export class BackupViewModel {
  /** 正在导出 / 正在生成快照（两者都是「写出文件」，页面据此禁用按钮 + 显示进度）。 */
  @Trace exporting: boolean = false;
  /** 正在导入。 */
  @Trace importing: boolean = false;
  /** 正在从快照恢复（也覆盖快照删除等写操作，页面据此禁用按钮）。 */
  @Trace restoring: boolean = false;
  /** 本地快照列表（新 → 旧）。 */
  @Trace snapshots: SnapshotInfo[] = [];
  /** 最近一次导入 / 恢复的统计；undefined = 还没跑过。 */
  @Trace summary: BackupSummary | undefined = undefined;
  /** 最近一次失败的错误 key（BackupError 常量；成功时回到空串）。 */
  @Trace lastError: string = BackupError.NONE;
  /** 最近一次动作是否被用户取消（true 时页面只提示「已取消」，不弹错误）。 */
  @Trace lastCancelled: boolean = false;
  /** 最近一次成功动作的时间戳（毫秒）；0 = 本次会话还没成功过。 */
  @Trace lastActionAt: number = 0;
  /** 导入 / 恢复时是否同时应用备份里的设置（默认关，避免覆盖本机偏好）。 */
  @Trace restoreSettings: boolean = false;
  /** 是否有可用的云空间目录（系统版本 / 云空间版本过低时为 false）。 */
  @Trace cloudAvailable: boolean = false;
  /** 云空间备份是否存在。 */
  @Trace cloudExists: boolean = false;
  /** 云空间备份的最后修改时间（毫秒）；0 = 不存在。 */
  @Trace cloudAt: number = 0;

  /** 是否有任何长任务在跑（页面据此禁用全部按钮）。 */
  busy(): boolean {
    return this.exporting || this.importing || this.restoring;
  }

  /** 「同时恢复设置」开关。 */
  setRestoreSettings(value: boolean): void {
    this.restoreSettings = value;
  }

  /**
   * 导出到用户选择的文件。
   * 返回 true 表示已写出；false 表示锁被占用 / 用户取消 / 写入失败。
   * 取消时 lastCancelled = true 且 lastError 保持空串；失败时 lastError = BackupError.EXPORT。
   * 失败不抛异常。
   */
  async exportNow(context: common.Context): Promise<boolean> {
    if (this.busy()) {
      return false;
    }
    this.exporting = true;
    this.lastError = BackupError.NONE;
    this.lastCancelled = false;
    try {
      const status: BackupRunStatus = await backupService.exportToFile(context);
      if (status === BackupRunStatus.CANCELLED) {
        this.lastCancelled = true;
        return false;
      }
      if (status === BackupRunStatus.BUSY) {
        // 自动快照等后台任务正在读写，什么都没做；提示稍后重试而不是「写入失败」。
        this.lastError = BackupError.BUSY;
        return false;
      }
      if (status !== BackupRunStatus.DONE) {
        this.lastError = BackupError.EXPORT;
        return false;
      }
      this.lastActionAt = Date.now();
      return true;
    } catch (err) {
      this.lastError = BackupError.EXPORT;
      return false;
    } finally {
      this.exporting = false;
    }
  }

  /**
   * 从用户选择的文件导入并合并。
   * 成功后刷新订阅列表、文章列表与各入口计数；返回统计供页面展示。
   * 取消时返回 undefined 且 lastCancelled = true；解析失败 / 锁被占用返回 undefined 且设置 lastError
   * （服务层保证这两种情况都未改动任何数据）。
   */
  async importNow(context: common.Context): Promise<BackupSummary | undefined> {
    if (this.busy()) {
      return undefined;
    }
    this.importing = true;
    this.lastError = BackupError.NONE;
    this.lastCancelled = false;
    try {
      const result: BackupImportResult =
        await backupService.importFromFile(context, this.restoreSettings);
      if (result.busy()) {
        // 后台任务（自动快照）占用串行锁：未读取任何文件，直接提示稍后重试。
        this.lastError = BackupError.BUSY;
        return undefined;
      }
      if (result.cancelled()) {
        this.lastCancelled = true;
        return undefined;
      }
      if (!result.ok() || result.summary === undefined) {
        this.lastError = BackupError.IMPORT;
        return undefined;
      }
      this.summary = result.summary;
      this.lastActionAt = Date.now();
      await this.refreshAfterImport(context);
      return result.summary;
    } catch (err) {
      this.lastError = BackupError.IMPORT;
      return undefined;
    } finally {
      this.importing = false;
    }
  }

  /** 刷新云空间备份状态（页面进入时调用）。 */
  refreshCloud(context: common.Context): void {
    const info: CloudBackupInfo = backupService.cloudInfo(context);
    this.cloudAvailable = info.available;
    this.cloudExists = info.exists;
    this.cloudAt = info.at;
  }

  /**
   * 备份到用户云空间（端云文件协同，固定文件名只保留最新一份）。
   * 返回 true 表示已写入云目录，系统随后自动上云并同步到同账号设备。
   */
  async backupToCloud(context: common.Context): Promise<boolean> {
    if (this.busy()) {
      return false;
    }
    this.exporting = true;
    this.lastError = BackupError.NONE;
    this.lastCancelled = false;
    try {
      const status: BackupRunStatus = await backupService.backupToCloud(context);
      if (status === BackupRunStatus.BUSY) {
        this.lastError = BackupError.BUSY;
        return false;
      }
      if (status !== BackupRunStatus.DONE) {
        this.lastError = BackupError.EXPORT;
        this.refreshCloud(context);
        return false;
      }
      this.lastActionAt = Date.now();
      this.refreshCloud(context);
      return true;
    } catch (err) {
      this.lastError = BackupError.EXPORT;
      return false;
    } finally {
      this.exporting = false;
    }
  }

  /** 从云空间备份恢复（合并，不删除本地数据）；成功后刷新订阅与各计数。 */
  async restoreFromCloud(context: common.Context): Promise<BackupSummary | undefined> {
    if (this.busy()) {
      return undefined;
    }
    this.importing = true;
    this.lastError = BackupError.NONE;
    this.lastCancelled = false;
    try {
      const result: BackupImportResult =
        await backupService.restoreFromCloud(context, this.restoreSettings);
      if (result.busy()) {
        this.lastError = BackupError.BUSY;
        return undefined;
      }
      if (!result.ok() || result.summary === undefined) {
        this.lastError = BackupError.IMPORT;
        return undefined;
      }
      this.summary = result.summary;
      this.lastActionAt = Date.now();
      await this.refreshAfterImport(context);
      return result.summary;
    } catch (err) {
      this.lastError = BackupError.IMPORT;
      return undefined;
    } finally {
      this.importing = false;
    }
  }

  /** 立即生成一份当日快照；成功后刷新快照列表。 */
  async snapshotNow(context: common.Context): Promise<boolean> {
    if (this.busy()) {
      return false;
    }
    this.exporting = true;
    this.lastError = BackupError.NONE;
    this.lastCancelled = false;
    try {
      const info: SnapshotInfo | undefined = await backupService.snapshotNow(context);
      if (info === undefined) {
        this.lastError = BackupError.SNAPSHOT;
        return false;
      }
      this.lastActionAt = Date.now();
      await this.refreshSnapshots(context);
      return true;
    } catch (err) {
      this.lastError = BackupError.SNAPSHOT;
      return false;
    } finally {
      this.exporting = false;
    }
  }

  /** 用某份快照恢复（合并，不删除本地数据）；成功后刷新订阅与计数。 */
  async restore(context: common.Context, info: SnapshotInfo): Promise<boolean> {
    if (this.busy()) {
      return false;
    }
    this.restoring = true;
    this.lastError = BackupError.NONE;
    this.lastCancelled = false;
    try {
      const result: BackupSummary | undefined = await backupService.restoreSnapshot(context, info);
      if (result === undefined) {
        this.lastError = BackupError.SNAPSHOT;
        return false;
      }
      this.summary = result;
      this.lastActionAt = Date.now();
      await this.refreshAfterImport(context);
      return true;
    } catch (err) {
      this.lastError = BackupError.SNAPSHOT;
      return false;
    } finally {
      this.restoring = false;
    }
  }

  /** 删除一份快照；成功即刷新列表（列表项顺序与保留份数由服务层保证）。 */
  async remove(context: common.Context, info: SnapshotInfo): Promise<boolean> {
    if (this.busy()) {
      return false;
    }
    this.restoring = true;
    this.lastError = BackupError.NONE;
    this.lastCancelled = false;
    try {
      const ok: boolean = await backupService.deleteSnapshot(context, info);
      if (!ok) {
        this.lastError = BackupError.SNAPSHOT;
        return false;
      }
      await this.refreshSnapshots(context);
      return true;
    } catch (err) {
      this.lastError = BackupError.SNAPSHOT;
      return false;
    } finally {
      this.restoring = false;
    }
  }

  /** 重新读取本地快照列表（进入页面 / 动作完成后调用）。 */
  async refreshSnapshots(context: common.Context): Promise<void> {
    try {
      this.snapshots = await backupService.listSnapshots(context);
      if (this.lastError === BackupError.SNAPSHOT) {
        this.lastError = BackupError.NONE;
      }
    } catch (err) {
      this.snapshots = [];
      this.lastError = BackupError.SNAPSHOT;
    }
  }

  /**
   * 导入 / 恢复成功后的界面刷新。
   *
   * 顺序：先重载订阅与文章（页面主列表立刻反映新数据），再刷新快照列表，
   * 最后刷新标签 / 规则 / 智能文件夹计数 —— 计数只是入口角标，失败也不影响主流程。
   */
  private async refreshAfterImport(context: common.Context): Promise<void> {
    await feedViewModel.reloadAfterBackup(context);
    await this.refreshSnapshots(context);
    try {
      await tagViewModel.load();
    } catch (err) {
      // 计数刷新失败不影响导入结果：下次进入对应页面会重新加载。
    }
    try {
      await ruleViewModel.load();
    } catch (err) {
      // 同上。
    }
    try {
      await smartFolderViewModel.load();
    } catch (err) {
      // 同上。
    }
  }
}

/** 全局唯一 ViewModel。 */
export const backupViewModel: BackupViewModel = new BackupViewModel();
