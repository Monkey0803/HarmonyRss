/*
 * List.test.ets — 单元测试套件入口（聚合各测试文件）。
 *
 * 覆盖 Reader 正文提取管线的纯函数（HTML 解析 / 净化 / 主容器提取 / feed 解析 / 图片 mime 嗅探），
 * 阅读排版档位与 Reader CSS 生成，规则引擎的匹配 / 执行顺序（RuleEngine / RuleOrder），
 * 跨源去重的归一化键与匹配决策（DedupeKeys / DedupePlan），
 * 备份编解码与订阅合并（BackupCodec / BackupMerge），
 * 以及分享目标 URI 构造与分享模板渲染（ShareTargets / ShareTemplates）。
 */

import htmlDomTest from './HtmlDom.test';
import htmlSanitizerTest from './HtmlSanitizer.test';
import readabilityTest from './Readability.test';
import rssParserTest from './RssParser.test';
import mimeSniffTest from './MimeSniff.test';
import readerTypographyTest from './ReaderTypography.test';
import readerBudgetTest from './ReaderBudget.test';
import urlTextTest from './UrlText.test';
import feedDiscoveryTest from './FeedDiscovery.test';
import opmlCodecTest from './OpmlCodec.test';
import shareIntentTest from './ShareIntent.test';
import searchQueryParserTest from './SearchQueryParser.test';
import cjkTokenizerTest from './CjkTokenizer.test';
import searchPlanTest from './SearchPlan.test';
import retentionTest from './Retention.test';
import feedStoreTest from './FeedStore.test';
import backupCodecTest from './BackupCodec.test';
import backupMergeTest from './BackupMerge.test';
import tagStoreTest from './TagStore.test';
import smartFolderTest from './SmartFolder.test';
import searchPerfTest from './SearchPerf.test';
import gReaderModelsTest from './GReaderModels.test';
import remoteSyncPlanTest from './RemoteSyncPlan.test';
import ruleEngineTest from './RuleEngine.test';
import ruleOrderTest from './RuleOrder.test';
import dedupeKeysTest from './DedupeKeys.test';
import dedupePlanTest from './DedupePlan.test';
import dedupeIntegrationTest from './DedupeIntegration.test';
import shareTargetsTest from './ShareTargets.test';
import shareTemplatesTest from './ShareTemplates.test';
import notifyPolicyTest from './NotifyPolicy.test';
import notifyQueueTest from './NotifyQueue.test';
import httpClientTest from './HttpClient.test';
import translationPolicyTest from './TranslationPolicy.test';
import enclosureTest from './Enclosure.test';
import discoverTest from './Discover.test';
import diagnosticsTest from './Diagnostics.test';
import feedbinModelsTest from './FeedbinModels.test';
import syncMergeTest from './SyncMerge.test';
import syncEngineTest from './SyncEngine.test';
import syncCollectorTest from './SyncCollector.test';
import syncContentTest from './SyncContent.test';
import autoSyncPolicyTest from './AutoSyncPolicy.test';
import cloudBackupTest from './CloudBackup.test';
import cloudRelayTest from './CloudRelay.test';

export default function testsuite() {
  htmlDomTest();
  htmlSanitizerTest();
  readabilityTest();
  rssParserTest();
  mimeSniffTest();
  readerTypographyTest();
  readerBudgetTest();
  urlTextTest();
  feedDiscoveryTest();
  opmlCodecTest();
  shareIntentTest();
  searchQueryParserTest();
  cjkTokenizerTest();
  searchPlanTest();
  retentionTest();
  feedStoreTest();
  backupCodecTest();
  backupMergeTest();
  tagStoreTest();
  smartFolderTest();
  searchPerfTest();
  gReaderModelsTest();
  remoteSyncPlanTest();
  ruleEngineTest();
  ruleOrderTest();
  dedupeKeysTest();
  dedupePlanTest();
  dedupeIntegrationTest();
  shareTargetsTest();
  shareTemplatesTest();
  notifyPolicyTest();
  notifyQueueTest();
  httpClientTest();
  translationPolicyTest();
  enclosureTest();
  discoverTest();
  diagnosticsTest();
  feedbinModelsTest();
  syncMergeTest();
  syncEngineTest();
  syncCollectorTest();
  syncContentTest();
  autoSyncPolicyTest();
  cloudBackupTest();
  cloudRelayTest();
}
