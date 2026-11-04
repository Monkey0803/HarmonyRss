/* Ordered, fault-isolated application of a parsed backup document. */
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BackupArticleTag, BackupDocument, BackupHighlight, BackupSummary, BackupTemplate } from '../model/Backup';
import { FeedSource } from '../model/Feed';
import { ShareTemplate } from '../model/Share';
import { articleDatabase, articleRepository, highlightStore, BackupMergeCount } from './ArticleServices';
import { feedStore, mergeFeedsForBackup } from './FeedStore';
import { TagMergeResult, tagStore } from './TagStore';
import { smartFolderStore } from './SmartFolderStore';
import { ruleStore } from './RuleStore';
import { settingsStore } from './SettingsStore';
import { shareTemplates } from './ShareTemplates';
import { ThemeController } from './ThemeController';
import { LocaleController } from './LocaleController';
import { appSettings } from '../model/AppSettings';
import { ArticleDbConstants } from '../common/constants/RssConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'BackupImportApplier';
function logFailure(action: string, err: Object): void {
  const detail: string = err instanceof Error ? err.message : 'unknown error';
  hilog.error(DOMAIN, TAG, '%{public}s failed: %{public}s', action, detail);
}

export class BackupImportApplier {
  private onApplied: () => void;
  constructor(onApplied: () => void) { this.onApplied = onApplied; }

  async applyDocument(context: common.Context, doc: BackupDocument,
    restoreSettings: boolean): Promise<BackupSummary> {
    const summary: BackupSummary = BackupSummary.empty();
    // 冷启动 / 分享扩展等入口可能还没打开库：先等就绪，拿不到库时各段自然降级为空操作。
    await articleDatabase.whenReady();

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
      const counts: BackupMergeCount = await articleRepository.mergeArticlesForBackup(doc.articles, validFeedIds);
      summary.articlesAdded = counts.added;
      summary.articlesUpdated = counts.updated;
      summary.skipped += counts.skipped;
    } catch (err) {
      logFailure('applyArticles', err as Object);
      summary.failed += 1;
    }

    // 文章 id 快照：高亮与标签关联都要求文章存在（含刚插入的那些）。
    const needsArticleIds: boolean = doc.highlights.length > 0 || doc.articleTags.length > 0;
    const articleIds: Set<string> = needsArticleIds ? await this.existingArticleIds() : new Set<string>();

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
      summary.highlightsAdded = await highlightStore.mergeHighlightsForBackup(accepted);
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
      const linksAdded: number = await tagStore.mergeArticleTagsForBackup(links);
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
    this.onApplied();

    return summary;
  }

  private async existingArticleIds(): Promise<Set<string>> {
    const ids: Set<string> = new Set<string>();
    const store: relationalStore.RdbStore | undefined = articleDatabase.getStore();
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
}
