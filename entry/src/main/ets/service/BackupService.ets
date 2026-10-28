/*
 * BackupService.ets — 备份 / 迁移的编排层（聚合导出、合并导入、快照管理）。
 *
 * 职责边界：
 *   - 导出：把各 Store 的全量数据聚合成 BackupDocument → BackupCodec.serialize → 系统选择器保存；
 *   - 导入：选择器读文本 → BackupCodec.parse（版本校验）→ applyDocument 执行合并；
 *   - 快照：私有目录按日期写 JSON（同一天覆盖），保留最近 N 份，preferences 记录最近生成时间。
 *
 * 三条硬约束（与 spec / plan 一致）：
 *   1) 合并不删除：各段只做 INSERT OR IGNORE / 状态并集，导入失败不改动任何既有数据；
 *   2) 逐段隔离：单段异常只计 failed 并继续下一段，绝不因一条脏数据中断整次导入；
 *   3) 串行执行：导出 / 导入 / 快照共用一把内存锁（busy），避免合并过程中被另一条链路读到半套数据。
 *
 * 依赖方向：本文件不 import 任何 ViewModel（避免 ViewModel ↔ Service 循环依赖）；
 * 导入后的界面刷新由 BackupViewModel 负责。
 */

import { common } from '@kit.AbilityKit';
import { preferences, relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  BackupArticleTag,
  BackupDocument,
  BackupHighlight,
  BackupSummary,
  BackupTemplate,
  SnapshotInfo
} from '../model/Backup';
import { FeedSource } from '../model/Feed';
import { ShareTemplate } from '../model/Share';
import { parse, sanitizeFeed, serialize } from './BackupCodec';
import {
  backupFileName,
  CloudBackupInfo,
  cloudBackupInfo,
  deleteSnapshot as deleteSnapshotFile,
  listSnapshots as listSnapshotFiles,
  PickerOutput,
  PickerStatus,
  prune,
  readCloudBackup,
  readSnapshot,
  saveViaPicker,
  selectViaPicker,
  writeCloudBackup,
  writeSnapshot
} from './BackupFiles';
import { articleStore, BackupMergeCount } from './ArticleStore';
import { feedStore, mergeFeedsForBackup } from './FeedStore';
import { TagMergeResult, tagStore } from './TagStore';
import { smartFolderStore } from './SmartFolderStore';
import { ruleStore } from './RuleStore';
import { settingsStore } from './SettingsStore';
import { shareTemplates } from './ShareTemplates';
import { ThemeController } from './ThemeController';
import { LocaleController } from './LocaleController';
import { appSettings } from '../model/AppSettings';
import { ArticleDbConstants, RssConstants } from '../common/constants/RssConstants';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'BackupService';

/** 自动快照间隔：距上次快照不足 24 小时则本次启动跳过（同一天只留一份）。 */
const SNAPSHOT_INTERVAL_MS: number = 24 * 60 * 60 * 1000;

/** 异常可能不是 Error（如 JSON 解析的 SyntaxError 无 code 字段），统一只读 message。 */
function logFailure(action: string, err: Object): void {
  const detail: string = err instanceof Error ? err.message : 'unknown error';
  hilog.error(DOMAIN, TAG, '%{public}s failed: %{public}s', action, detail);
}

/** 一次用户可见动作（导出 / 导入）的结局：UI 据此区分成功、取消、失败与「另一条链路正在跑」。 */
export enum BackupRunStatus {
  DONE = 0,
  CANCELLED = 1,
  FAILED = 2,
  /** 串行锁被占用（典型：启动时的自动快照还没写完）：什么都没做，可直接重试。 */
  BUSY = 3
}

/** 导入结果：status 决定提示文案；summary 只在 DONE 时有值。 */
export class BackupImportResult {
  status: BackupRunStatus;
  summary: BackupSummary | undefined;

  constructor(status: BackupRunStatus, summary: BackupSummary | undefined = undefined) {
    this.status = status;
    this.summary = summary;
  }

  ok(): boolean {
    return this.status === BackupRunStatus.DONE && this.summary !== undefined;
  }

  cancelled(): boolean {
    return this.status === BackupRunStatus.CANCELLED;
  }

  busy(): boolean {
    return this.status === BackupRunStatus.BUSY;
  }
}

export class BackupService {
  /**
   * 串行锁：导出 / 导入 / 快照互斥。
   * 这些链路都会长时间读写同一批表，交叉执行会读到「合并到一半」的数据；
   * busy 期间后来的请求直接放弃（导出 / 导入返回 BUSY，快照类返回 false / undefined），由 UI 提示稍后再试。
   */
  private busy: boolean = false;
  /** 后台索引重建是否在跑（同一时间只允许一条重建链路）。 */
  private rebuilding: boolean = false;
  /** 重建期间又来了导入：跑完后再补一轮，保证索引覆盖到最后写入的行。 */
  private rebuildPending: boolean = false;

  // ---- 导出 / 导入（用户可见链路） ----

  /**
   * 导出全部数据到用户选择的 JSON 文件。
   * 返回 DONE / CANCELLED（用户取消保存面板）/ BUSY（自动快照等正在跑）/ FAILED（序列化或写入失败）。
   * 本方法不抛异常：所有失败都折算成 status，由 BackupViewModel 转成页面提示。
   */
  async exportToFile(context: common.Context): Promise<BackupRunStatus> {
    if (this.busy) {
      return BackupRunStatus.BUSY;
    }
    this.busy = true;
    try {
      const doc: BackupDocument = await this.collect(context);
      const text: string = serialize(doc);
      if (text.length === 0) {
        hilog.warn(DOMAIN, TAG, 'export aborted: serialize produced empty text');
        return BackupRunStatus.FAILED;
      }
      const status: PickerStatus = await saveViaPicker(context, text);
      if (status === PickerStatus.CANCELLED) {
        return BackupRunStatus.CANCELLED;
      }
      return status === PickerStatus.DONE ? BackupRunStatus.DONE : BackupRunStatus.FAILED;
    } catch (err) {
      logFailure('exportToFile', err as Object);
      return BackupRunStatus.FAILED;
    } finally {
      this.busy = false;
    }
  }

  /**
   * 从用户选择的 JSON 文件导入并合并。
   * 取消选择 / 读取失败 / 版本不匹配 / JSON 损坏都折算成 status，且**不改动任何现有数据**
   * （parse 在 applyDocument 之前完成，解析失败时还没有开始写库）。
   */
  async importFromFile(context: common.Context,
    restoreSettings: boolean): Promise<BackupImportResult> {
    if (this.busy) {
      return new BackupImportResult(BackupRunStatus.BUSY);
    }
    this.busy = true;
    try {
      const picked: PickerOutput = await selectViaPicker(context);
      if (picked.status === PickerStatus.CANCELLED) {
        return new BackupImportResult(BackupRunStatus.CANCELLED);
      }
      if (picked.status !== PickerStatus.DONE) {
        return new BackupImportResult(BackupRunStatus.FAILED);
      }
      const doc: BackupDocument | undefined = parse(picked.text);
      if (doc === undefined) {
        hilog.warn(DOMAIN, TAG, 'import aborted: unparsable or version mismatch');
        return new BackupImportResult(BackupRunStatus.FAILED);
      }
      const summary: BackupSummary = await this.applyDocument(context, doc, restoreSettings);
      return new BackupImportResult(BackupRunStatus.DONE, summary);
    } catch (err) {
      logFailure('importFromFile', err as Object);
      return new BackupImportResult(BackupRunStatus.FAILED);
    } finally {
      this.busy = false;
    }
  }

  // ---- 云空间备份（端云文件协同，不依赖开发者服务端） ----

  /** 云空间备份状态：目录是否可用、是否已有备份、最后修改时间。 */
  cloudInfo(context: common.Context): CloudBackupInfo {
    return cloudBackupInfo(context);
  }

  /**
   * 备份到用户云空间：写 `context.cloudFileDir` 下的固定文件，
   * 端云协同服务会在写入完成后自动上云，并同步到同一华为账号的其他设备。
   */
  async backupToCloud(context: common.Context): Promise<BackupRunStatus> {
    if (this.busy) {
      return BackupRunStatus.BUSY;
    }
    this.busy = true;
    try {
      const doc: BackupDocument = await this.collect(context);
      const text: string = serialize(doc);
      if (text.length === 0) {
        hilog.warn(DOMAIN, TAG, 'cloud backup aborted: serialize produced empty text');
        return BackupRunStatus.FAILED;
      }
      return writeCloudBackup(context, text) ? BackupRunStatus.DONE : BackupRunStatus.FAILED;
    } catch (err) {
      logFailure('backupToCloud', err as Object);
      return BackupRunStatus.FAILED;
    } finally {
      this.busy = false;
    }
  }

  /**
   * 从云空间备份恢复并合并（不删除本地数据）。
   * 没有云备份 / 解析失败 / 版本不匹配 / 锁被占用都返回失败，且不改动任何现有数据。
   */
  async restoreFromCloud(context: common.Context,
    restoreSettings: boolean): Promise<BackupImportResult> {
    if (this.busy) {
      return new BackupImportResult(BackupRunStatus.BUSY);
    }
    this.busy = true;
    try {
      const text: string = readCloudBackup(context);
      if (text.length === 0) {
        hilog.info(DOMAIN, TAG, 'cloud restore skipped: no backup file');
        return new BackupImportResult(BackupRunStatus.FAILED);
      }
      const doc: BackupDocument | undefined = parse(text);
      if (doc === undefined) {
        hilog.warn(DOMAIN, TAG, 'cloud restore aborted: unparsable or version mismatch');
        return new BackupImportResult(BackupRunStatus.FAILED);
      }
      const summary: BackupSummary = await this.applyDocument(context, doc, restoreSettings);
      return new BackupImportResult(BackupRunStatus.DONE, summary);
    } catch (err) {
      logFailure('restoreFromCloud', err as Object);
      return new BackupImportResult(BackupRunStatus.FAILED);
    } finally {
      this.busy = false;
    }
  }

  /**
   * 执行一份已解析备份的合并（幂等；不删除任何本地数据）。
   *
   * 注意：本方法**不**自己加锁 —— 调用方（importFromFile / restoreSnapshot）必须已持有串行锁，
   * 否则会在内部再抢锁造成重入。逐段 try/catch：某一段失败只影响该段。
   *
   * 段顺序有依赖，不能随意调换：
   *   feeds → articles（需要合并后的 feedId 集合）→ articleIds 快照（供高亮 / 标签关联过滤）
   *   → highlights → tags（需要 tagId 映射）→ articleTags → 智能文件夹 / 规则 / 模板 / 设置。
   */
  async applyDocument(context: common.Context, doc: BackupDocument,
    restoreSettings: boolean): Promise<BackupSummary> {
    const summary: BackupSummary = BackupSummary.empty();
    // 冷启动 / 分享扩展等入口可能还没打开库：先等就绪，拿不到库时各段自然降级为空操作。
    await articleStore.whenReady();

    // 1) 订阅：按归一化 URL 合并，保留本地独有源与本地抓取状态。
    let mergedFeeds: FeedSource[] = [];
    try {
      const local: FeedSource[] = await feedStore.load(context, false);
      mergedFeeds = mergeFeedsForBackup(local, doc.feeds);
      feedStore.save(mergedFeeds);
      summary.feedsAdded = mergedFeeds.length - local.length;
    } catch (err) {
      logFailure('applyFeeds', err as Object);
      summary.failed += 1;
    }
    const validFeedIds: string[] = [];
    for (let i = 0; i < mergedFeeds.length; i += 1) {
      validFeedIds.push(mergedFeeds[i].id);
    }

    // 2) 文章：按 id 合并，状态取并集；feed 不在集合里的条目由 Store 计为 skipped。
    try {
      const counts: BackupMergeCount = await articleStore.mergeArticlesForBackup(doc.articles, validFeedIds);
      summary.articlesAdded = counts.added;
      summary.articlesUpdated = counts.updated;
      summary.skipped += counts.skipped;
    } catch (err) {
      logFailure('applyArticles', err as Object);
      summary.failed += 1;
    }

    // 文章 id 快照：高亮与标签关联都要求文章存在（含刚插入的那些）。
    const articleIds: Set<string> = await this.existingArticleIds();

    // 3) 高亮：文章不存在的条目跳过并计入 skipped。
    try {
      const accepted: BackupHighlight[] = [];
      for (let i = 0; i < doc.highlights.length; i += 1) {
        const item: BackupHighlight = doc.highlights[i];
        if (!articleIds.has(item.articleId)) {
          summary.skipped += 1;
          continue;
        }
        accepted.push(item);
      }
      summary.highlightsAdded = await articleStore.mergeHighlightsForBackup(accepted);
    } catch (err) {
      logFailure('applyHighlights', err as Object);
      summary.failed += 1;
    }

    // 4) 标签：按 name_key 合并；mapping 把备份 tagId 映射到本地真实 tagId。
    let tagMapping: Map<string, string> = new Map<string, string>();
    try {
      const merged: TagMergeResult = await tagStore.mergeForBackup(doc.tags);
      tagMapping = merged.mapping;
      summary.tagsAdded = merged.added;
    } catch (err) {
      logFailure('applyTags', err as Object);
      summary.failed += 1;
    }

    // 4b) 文章 ↔ 标签关联：文章必须存在，tagId 必须能经 mapping 改写（否则跳过）。
    try {
      const links: BackupArticleTag[] = [];
      for (let i = 0; i < doc.articleTags.length; i += 1) {
        const item: BackupArticleTag = doc.articleTags[i];
        const mappedTagId: string | undefined = tagMapping.get(item.tagId);
        if (mappedTagId === undefined || !articleIds.has(item.articleId)) {
          summary.skipped += 1;
          continue;
        }
        links.push(new BackupArticleTag(item.articleId, mappedTagId));
      }
      const linksAdded: number = await articleStore.mergeArticleTagsForBackup(links);
      // BackupSummary 没有标签关联字段：只记日志，避免为它改动对外的统计契约。
      hilog.info(DOMAIN, TAG, 'article tags merged: %{public}d', linksAdded);
    } catch (err) {
      logFailure('applyArticleTags', err as Object);
      summary.failed += 1;
    }

    // 5) 智能文件夹 / 规则：按 id 合并（存在即跳过，不覆盖本地编辑）。
    try {
      const foldersAdded: number = await smartFolderStore.mergeForBackup(doc.smartFolders);
      hilog.info(DOMAIN, TAG, 'smart folders merged: %{public}d', foldersAdded);
    } catch (err) {
      logFailure('applySmartFolders', err as Object);
      summary.failed += 1;
    }
    try {
      const rulesAdded: number = await ruleStore.mergeForBackup(doc.rules);
      hilog.info(DOMAIN, TAG, 'rules merged: %{public}d', rulesAdded);
    } catch (err) {
      logFailure('applyRules', err as Object);
      summary.failed += 1;
    }

    // 6) 分享模板：按 id 保留现有、追加缺失；有新增才写回（避免把默认模板落库）。
    try {
      await shareTemplates.open(context);
      const existing: ShareTemplate[] = await shareTemplates.list();
      const seen: Set<string> = new Set<string>();
      const merged: ShareTemplate[] = [];
      for (let i = 0; i < existing.length; i += 1) {
        const item: ShareTemplate = existing[i];
        seen.add(item.id);
        merged.push(item);
      }
      let added: number = 0;
      for (let i = 0; i < doc.templates.length; i += 1) {
        const item: BackupTemplate = doc.templates[i];
        if (seen.has(item.id)) {
          continue;
        }
        seen.add(item.id);
        merged.push(new ShareTemplate(item.id, item.name, item.content, merged.length));
        added += 1;
      }
      if (added > 0) {
        const saved: boolean = await shareTemplates.saveAll(merged);
        if (!saved) {
          summary.failed += 1;
        }
      }
    } catch (err) {
      logFailure('applyTemplates', err as Object);
      summary.failed += 1;
    }

    // 7) 设置：仅当用户显式勾选「同时恢复设置」才写入白名单键，并应用主题 / 语言副作用。
    if (restoreSettings) {
      try {
        settingsStore.applyWhitelisted(doc.settings);
        ThemeController.apply(context, appSettings.themeMode);
        LocaleController.apply(appSettings.languageMode);
      } catch (err) {
        logFailure('applySettings', err as Object);
        summary.failed += 1;
      }
    }

    // 8) 检索索引：整次导入结束后统一重建（导入期间不写索引，避免逐条建索引拖慢且产生重复行）。
    //    后台执行、不 await：索引只影响检索，不能阻塞导入结果返回。
    this.rebuildIndexesInBackground();

    return summary;
  }

  // ---- 自动快照 ----

  /** 立即生成一份当日快照；失败 / 锁被占用返回 undefined。 */
  async snapshotNow(context: common.Context): Promise<SnapshotInfo | undefined> {
    if (this.busy) {
      return undefined;
    }
    this.busy = true;
    try {
      const doc: BackupDocument = await this.collect(context);
      const text: string = serialize(doc);
      if (text.length === 0) {
        return undefined;
      }
      const fileName: string = backupFileName(new Date());
      const path: string = await writeSnapshot(context, fileName, text);
      if (path.length === 0) {
        return undefined;
      }
      // 保留策略：写成功后再清理，避免写失败时误删旧快照。
      await prune(context, RssConstants.BACKUP_SNAPSHOT_KEEP);
      await this.rememberSnapshotTime(context);
      const snapshots: SnapshotInfo[] = await listSnapshotFiles(context);
      for (let i = 0; i < snapshots.length; i += 1) {
        if (snapshots[i].fileName === fileName) {
          return snapshots[i];
        }
      }
      // 列表读不到刚写文件（极少数 IO 异常）：用内容长度近似体积，至少让 UI 有可展示的一条。
      return new SnapshotInfo(fileName, path, text.length, Date.now());
    } catch (err) {
      logFailure('snapshotNow', err as Object);
      return undefined;
    } finally {
      this.busy = false;
    }
  }

  /**
   * 启动时调用：距上次快照不足 24 小时直接返回，否则后台生成一份。
   * 同步返回、绝不 await —— 快照是兜底能力，不能拖慢首屏。
   */
  maybeAutoSnapshot(context: common.Context): void {
    this.runAutoSnapshot(context).catch((err: Object) => {
      logFailure('maybeAutoSnapshot', err);
    });
  }

  private async runAutoSnapshot(context: common.Context): Promise<void> {
    const last: number = await this.readSnapshotTime(context);
    if (last > 0 && Date.now() - last < SNAPSHOT_INTERVAL_MS) {
      return;
    }
    await this.snapshotNow(context);
  }

  // ---- 快照列表 / 恢复 / 删除 / 清理 ----

  /** 列出本地快照（新 → 旧）；库不可用 / 目录读失败返回空数组。 */
  async listSnapshots(context: common.Context): Promise<SnapshotInfo[]> {
    try {
      return await listSnapshotFiles(context);
    } catch (err) {
      logFailure('listSnapshots', err as Object);
      return [];
    }
  }

  /**
   * 用某份快照恢复：读文本 → parse → 合并（restoreSettings = true，快照本就是本机数据）。
   * 快照损坏或锁被占用返回 undefined。
   */
  async restoreSnapshot(context: common.Context, info: SnapshotInfo): Promise<BackupSummary | undefined> {
    if (this.busy) {
      return undefined;
    }
    this.busy = true;
    try {
      const text: string = await readSnapshot(info.path);
      if (text.length === 0) {
        return undefined;
      }
      const doc: BackupDocument | undefined = parse(text);
      if (doc === undefined) {
        hilog.warn(DOMAIN, TAG, 'restore aborted: unparsable snapshot');
        return undefined;
      }
      return await this.applyDocument(context, doc, true);
    } catch (err) {
      logFailure('restoreSnapshot', err as Object);
      return undefined;
    } finally {
      this.busy = false;
    }
  }

  /** 删除一份快照；成功 true。锁被占用 / 删除失败返回 false。 */
  async deleteSnapshot(context: common.Context, info: SnapshotInfo): Promise<boolean> {
    if (this.busy) {
      return false;
    }
    this.busy = true;
    try {
      return await deleteSnapshotFile(info.path);
    } catch (err) {
      logFailure('deleteSnapshot', err as Object);
      return false;
    } finally {
      this.busy = false;
    }
  }

  /** 按保留份数清理旧快照（手动触发；自动快照写成功后也会调用）。 */
  async pruneSnapshots(context: common.Context): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await prune(context, RssConstants.BACKUP_SNAPSHOT_KEEP);
    } catch (err) {
      logFailure('pruneSnapshots', err as Object);
    } finally {
      this.busy = false;
    }
  }

  // ---- 内部实现 ----

  /**
   * 聚合导出文档。
   * 每段都直接取 Store 的备份专用读取（只读元数据列 / 不含正文与凭据），
   * 设置只取白名单键（BackupCodec.settingsWhitelist）。
   */
  private async collect(context: common.Context): Promise<BackupDocument> {
    await articleStore.whenReady();
    const doc: BackupDocument = new BackupDocument();
    doc.exportedAt = Date.now();
    const feeds: FeedSource[] = await feedStore.load(context, false);
    for (let i = 0; i < feeds.length; i += 1) {
      doc.feeds.push(sanitizeFeed(feeds[i]));
    }
    doc.articles = await articleStore.allArticlesForBackup();
    doc.highlights = await articleStore.allHighlightsForBackup();
    doc.tags = await tagStore.allForBackup();
    doc.articleTags = await articleStore.allArticleTagsForBackup();
    doc.smartFolders = await smartFolderStore.allForBackup();
    doc.rules = await ruleStore.allForBackup();
    await shareTemplates.open(context);
    const templates: ShareTemplate[] = await shareTemplates.list();
    for (let i = 0; i < templates.length; i += 1) {
      const item: ShareTemplate = templates[i];
      doc.templates.push(new BackupTemplate(item.id, item.name, item.content, i));
    }
    doc.settings = settingsStore.exportWhitelisted();
    return doc;
  }

  /** 现有文章 id 集合（直接查主键列，比拉全量元数据轻得多）。 */
  private async existingArticleIds(): Promise<Set<string>> {
    const ids: Set<string> = new Set<string>();
    const store: relationalStore.RdbStore | undefined = articleStore.getStore();
    if (store === undefined) {
      return ids;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id FROM ' + ArticleDbConstants.TABLE_ARTICLES);
      try {
        while (rs.goToNextRow()) {
          ids.add(rs.getString(rs.getColumnIndex('id')));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      logFailure('existingArticleIds', err as Object);
    }
    return ids;
  }

  /** 后台重建检索索引：串行执行（两个索引都写 FTS 表，避免同库并发写），失败只记日志。 */
  private rebuildIndexesInBackground(): void {
    if (this.rebuilding) {
      // 已有一次重建在跑：标记「跑完再来一遍」，避免两次连续导入并发写 FTS（也避免漏掉后导入的行）。
      this.rebuildPending = true;
      return;
    }
    this.rebuilding = true;
    this.runRebuildLoop();
  }

  private async runRebuildLoop(): Promise<void> {
    try {
      do {
        this.rebuildPending = false;
        await articleStore.rebuildSearchIndex((done: number, total: number): void => {
          // 无界面进度：导入结果已返回，索引在后台追赶。
        });
        await articleStore.rebuildCjkIndex((done: number, total: number): void => {
          // 同上。
        });
      } while (this.rebuildPending);
    } catch (err) {
      logFailure('rebuildIndexes', err as Object);
    } finally {
      this.rebuilding = false;
    }
  }

  /** 读最近一次快照时间；读不到按 0（下次启动会补一份）。 */
  private async readSnapshotTime(context: common.Context): Promise<number> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      const raw: preferences.ValueType =
        store.getSync(PreferencesConstants.KEY_LAST_SNAPSHOT_AT, 0);
      return typeof raw === 'number' ? raw : 0;
    } catch (err) {
      logFailure('readSnapshotTime', err as Object);
      return 0;
    }
  }

  /** 记录本次快照时间（用于 24 小时节流）；写失败只记日志。 */
  private async rememberSnapshotTime(context: common.Context): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      store.putSync(PreferencesConstants.KEY_LAST_SNAPSHOT_AT, Date.now());
      await store.flush();
    } catch (err) {
      logFailure('rememberSnapshotTime', err as Object);
    }
  }
}

/** 全局唯一实例。 */
export const backupService: BackupService = new BackupService();
