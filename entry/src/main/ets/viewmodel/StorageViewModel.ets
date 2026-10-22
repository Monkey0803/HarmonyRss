/*
 * StorageViewModel.ets — 「存储与保留」页的状态与编排（@ObservedV2）。
 *
 * 职责：加载统计 → 估算可清理条数 → 执行清理 / 恢复 / 重建索引 → 刷新列表与统计。
 * 二次确认、SnackBar 等交互留在 View；这里只做业务。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { SearchDiagnostics, StorageStats } from '../model/Search';
import { articleStore } from '../service/ArticleStore';
import { retentionService } from '../service/RetentionService';
import { feedViewModel } from './FeedViewModel';
import { settingsViewModel } from './SettingsViewModel';

@ObservedV2
export class StorageViewModel {
  /** 统计快照（总条数 / 文本占用 / 按源占用 / 可清理 / 回收站）。 */
  @Trace stats: StorageStats = StorageStats.empty();
  /** 检索索引诊断（主索引 / 中文索引 / 分词能力 / 条数 / 最近检索路径与耗时）。 */
  @Trace diagnostics: SearchDiagnostics = SearchDiagnostics.empty();
  /** 当前策略下可清理条数（清理前预览）。 */
  @Trace cleanable: number = 0;
  /** 首次加载中。 */
  @Trace loading: boolean = false;
  /** 正在清理。 */
  @Trace cleaning: boolean = false;
  /** 正在恢复。 */
  @Trace restoring: boolean = false;
  /** 正在重建索引。 */
  @Trace rebuilding: boolean = false;
  @Trace rebuildDone: number = 0;
  @Trace rebuildTotal: number = 0;
  /** 最近一次清理 / 恢复的条数（供提示文案）。 */
  @Trace lastCleaned: number = 0;
  @Trace lastRestored: number = 0;
  /** 加载失败（库不可用）。 */
  @Trace failed: boolean = false;

  /** 读取统计与可清理条数。 */
  async load(): Promise<void> {
    this.loading = true;
    this.failed = false;
    try {
      // 源级保留天数参与估算，先把订阅源同步给保留服务。
      retentionService.setFeeds(feedViewModel.feeds);
      this.cleanable = await retentionService.estimate();
      this.stats = await articleStore.storageStats(this.cleanable);
      await this.refreshDiagnostics();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.warn('storage load failed: ' + error.message);
      this.failed = true;
      this.stats = StorageStats.empty();
      this.diagnostics = SearchDiagnostics.empty();
    } finally {
      this.loading = false;
    }
  }

  /** 刷新检索索引诊断（存储页展示「检索索引」分组）。 */
  async refreshDiagnostics(): Promise<void> {
    try {
      this.diagnostics = await articleStore.diagnostics();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.warn('storage diagnostics failed: ' + error.message);
      this.diagnostics = SearchDiagnostics.empty();
    }
  }

  /** 立即清理（调用方负责二次确认）。返回实际清理条数。 */
  async cleanNow(): Promise<number> {
    if (this.cleaning) {
      return 0;
    }
    this.cleaning = true;
    try {
      this.lastCleaned = await retentionService.runNow();
      // 清理 / 恢复后刷新文章列表（当前打开的文章已被保留服务保护）。
      await feedViewModel.reloadAfterRetention();
      await this.load();
      return this.lastCleaned;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.warn('retention clean failed: ' + error.message);
      return 0;
    } finally {
      this.cleaning = false;
    }
  }

  /** 恢复回收站全部文章（7 天内）。 */
  async restoreAll(): Promise<number> {
    if (this.restoring) {
      return 0;
    }
    this.restoring = true;
    try {
      this.lastRestored = await retentionService.restoreAll();
      await feedViewModel.reloadAfterRetention();
      await this.load();
      return this.lastRestored;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.warn('retention restore failed: ' + error.message);
      return 0;
    } finally {
      this.restoring = false;
    }
  }

  /** 重建检索索引（主索引 + 中文索引，分批 + 进度回调，不阻塞阅读）。 */
  async rebuildIndex(): Promise<void> {
    if (this.rebuilding) {
      return;
    }
    this.rebuilding = true;
    this.rebuildDone = 0;
    this.rebuildTotal = 0;
    try {
      await articleStore.rebuildSearchIndex((done: number, total: number) => {
        this.rebuildDone = done;
        this.rebuildTotal = total;
      });
      await articleStore.rebuildCjkIndex((done: number, total: number) => {
        this.rebuildDone = done;
        this.rebuildTotal = total;
      });
      await this.refreshDiagnostics();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.warn('rebuild index failed: ' + error.message);
    } finally {
      this.rebuilding = false;
    }
  }

  /** 保留模式切换：保存后重新估算。 */
  async setMode(id: string): Promise<void> {
    settingsViewModel.setRetentionMode(id);
    await this.load();
  }

  /** 保留天数切换：保存后重新估算。 */
  async setDays(id: string): Promise<void> {
    settingsViewModel.setRetentionDays(id);
    await this.load();
  }

  /** 索引重建进度文案用的比例（0–1；未开始时 0）。 */
  progressRatio(): number {
    if (this.rebuildTotal <= 0) {
      return 0;
    }
    return Math.min(1, this.rebuildDone / this.rebuildTotal);
  }
}

/** 全局唯一实例。 */
export const storageViewModel: StorageViewModel = new StorageViewModel();
