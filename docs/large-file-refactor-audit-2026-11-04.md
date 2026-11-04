# 长文件职责审查与实施记录

快照日期：2026-11-04。范围：`entry/src/main/ets` 中超过 400 行的 `.ets` 文件。行数是定位线索，不是拆分验收条件。

| 文件 | 行数 | 结论 | 职责依据 | 验证状态 |
| --- | ---: | --- | --- | --- |
| `entry/src/main/ets/views/ArticleDetailView.ets` | 3518 | 拆分 | 阅读会话、进度、查找、媒体与页面状态混合 | 主包和测试 HAP 编译通过；ReaderProgressQueue；阅读进度排队写入与会话隔离；真机待复测 |
| `entry/src/main/ets/viewmodel/FeedViewModel.ets` | 2356 | 拆分 | 抓取、列表投影、订阅管理和阅读操作混合 | 主包和测试 HAP 编译通过；FeedArticleFilter、FeedGroupProjection；筛选和分组投影；真机待复测 |
| `entry/src/main/ets/service/ArticleRepository.ets` | 1860 | 拆分 | 备份、去重、回收站和文章查询混合 | 主包和测试 HAP 编译通过；ArticleBackupRepository、ArticleDedupeStore；备份与去重；真机待复测 |
| `entry/src/main/ets/service/sync/SyncCollector.ets` | 1193 | 拆分 | 多种记录的采集与应用集中在一类 | 主包和测试 HAP 编译通过；SyncSnapshotCollector、SyncSnapshotApplier、SyncCollectorShared；采集与应用；真机待复测 |
| `entry/src/main/ets/views/DiscoverView.ets` | 1022 | 拆分 | 发现列表、RSSHub、预览和导入交互混合 | 主包和测试 HAP 编译通过；DiscoverSearchField；搜索输入及事件；真机待复测 |
| `entry/src/main/ets/service/remote/RemoteSyncService.ets` | 933 | 拆分 | 拉取、推送、迁移及账号状态编排混合 | 主包和测试 HAP 编译通过；RemoteMigrationStateStore、RemoteStateTransfer；迁移状态与已读收藏传输；真机待复测 |
| `entry/src/main/ets/pages/Index.ets` | 885 | 拆分 | 导航、深链、响应式布局及页签状态混合 | 主包和测试 HAP 编译通过；IndexAddSheetContent；添加面板状态与回调；真机待复测 |
| `entry/src/main/ets/views/SubscriptionsView.ets` | 767 | 拆分 | 列表行状态展示、编辑和页面编排混合 | 主包和测试 HAP 编译通过；SubscriptionFeedStatus；订阅源行状态；真机待复测 |
| `entry/src/main/ets/views/BackupView.ets` | 740 | 拆分 | 本地与云端备份流程及页面展示混合 | 主包和测试 HAP 编译通过；BackupComponents；快照行与结果展示；真机待复测 |
| `entry/src/main/ets/service/SettingsStore.ets` | 730 | 拆分 | 偏好读写、备份白名单和站点偏好混合 | 主包和测试 HAP 编译通过；ReaderSitePreferenceStore；站点阅读偏好；真机待复测 |
| `entry/src/main/ets/model/Sync.ets` | 716 | 拆分 | 同步载荷模型、编解码与合并规则混合 | 主包和测试 HAP 编译通过；SyncModels、SyncPayloadCodec、SyncMerge；模型、编解码与合并；真机待复测 |
| `entry/src/main/ets/views/HomeTabView.ets` | 707 | 拆分 | 首页列表、空态、批量操作和面板混合 | 主包和测试 HAP 编译通过；HomeEmptyState；空态与添加事件；真机待复测 |
| `entry/src/main/ets/service/BackupService.ets` | 688 | 拆分 | 本地、云端、快照及导入恢复流程混合 | 主包和测试 HAP 编译通过；BackupImportApplier；导入应用处理；真机待复测 |
| `entry/src/main/ets/service/MediaPlayerService.ets` | 643 | 拆分 | 播放队列、系统会话和进度持久化混合 | 主包和测试 HAP 编译通过；MediaProgressStore、MediaBackgroundTask；进度与后台任务生命周期；真机待复测 |
| `entry/src/main/ets/views/NotifySettingsView.ets` | 640 | 拆分 | 权限、策略、免打扰及摘要设置混合 | 主包和测试 HAP 编译通过；NotifyPermissionCard；授权状态与事件；真机待复测 |
| `entry/src/main/ets/service/TagStore.ets` | 629 | 拆分 | 标签定义、关联、统计和备份搬运混合 | 主包和测试 HAP 编译通过；TagRelationsBackup；标签关联备份搬运；真机待复测 |
| `entry/src/main/ets/service/ArticleSearchStore.ets` | 625 | 保留 | 单一全文检索领域实现 | 已审查，待最终复核 |
| `entry/src/main/ets/service/SyncService.ets` | 601 | 拆分 | 同步开关、后端选择、执行和重试混合 | 主包和测试 HAP 编译通过；SyncRetryScheduler；失败退避定时器；真机待复测 |
| `entry/src/main/ets/views/ShareSheet.ets` | 568 | 拆分 | 分享动作、模板和导出面板混合 | 主包和测试 HAP 编译通过；ShareSheetRows；动作与模板行；真机待复测 |
| `entry/src/main/ets/service/RuleStore.ets` | 558 | 拆分 | 规则 CRUD、命中统计和备份搬运混合 | 主包和测试 HAP 编译通过；RuleSampleStore；规则试运行采样；真机待复测 |
| `entry/src/main/ets/service/ArticleDatabase.ets` | 554 | 拆分 | 共享连接、结构修复和索引生命周期混合 | 主包和测试 HAP 编译通过；ArticleTableMigrator；建表与结构修复；真机待复测 |
| `entry/src/main/ets/service/BackupCodec.ets` | 546 | 拆分 | 序列化、校验、白名单和合并策略混合 | 主包和测试 HAP 编译通过；BackupPolicy；字段白名单与合并策略；真机待复测 |
| `entry/src/main/ets/service/Readability.ets` | 540 | 保留 | 单一正文提取算法 | 已审查，待最终复核 |
| `entry/src/main/ets/views/SearchView.ets` | 533 | 拆分 | 搜索结果与智能文件夹保存流程混合 | 主包和测试 HAP 编译通过；SearchSnippetText；命中片段展示；真机待复测 |
| `entry/src/main/ets/service/RssParser.ets` | 526 | 保留 | 单一 Feed 解析算法 | 已审查，待最终复核 |
| `entry/src/main/ets/views/SyncView.ets` | 524 | 拆分 | 同步状态、后端设置和重置流程混合 | 主包和测试 HAP 编译通过；SyncConflictSummary；冲突摘要展示；真机待复测 |
| `entry/src/main/ets/views/RuleEditView.ets` | 519 | 保留 | 单一规则表单 | 已审查，待最终复核 |
| `entry/src/main/ets/service/ArticleSchema.ets` | 510 | 保留 | 共享表结构及 SQL 定义 | 已审查，待最终复核 |
| `entry/src/main/ets/service/ArticleContentService.ets` | 509 | 拆分 | 正文抓取、提取、图片内联与缓存落库混合 | 主包和测试 HAP 编译通过；ReaderInlineQueue；图片内联任务；真机待复测 |
| `entry/src/main/ets/views/DiagnosticsView.ets` | 506 | 保留 | 单一诊断展示页 | 已审查，待最终复核 |
| `entry/src/main/ets/views/AddFeedPanel.ets` | 495 | 拆分 | 地址输入、预览和批量添加阶段混合 | 主包和测试 HAP 编译通过；FeedPreviewItems；预览文章列表；真机待复测 |
| `entry/src/main/ets/service/HtmlSanitizer.ets` | 480 | 保留 | 单一 HTML 净化算法 | 已审查，待最终复核 |
| `entry/src/main/ets/views/RemoteServiceView.ets` | 477 | 保留 | 单一远端账号设置页 | 已审查，待最终复核 |
| `entry/src/main/ets/service/ReaderSpeech.ets` | 475 | 保留 | 单一语音播放生命周期 | 已审查，待最终复核 |
| `entry/src/main/ets/views/ShareSettingsView.ets` | 474 | 拆分 | 模板列表管理与编辑表单混合 | 主包和测试 HAP 编译通过；TemplateManageRow；模板管理行；真机待复测 |
| `entry/src/main/ets/service/NotifyService.ets` | 468 | 拆分 | 通知聚合策略、排队与系统发布混合 | 主包和测试 HAP 编译通过；NotificationPublisher；系统通知发布和点击动作；真机待复测 |
| `entry/src/main/ets/service/BackupFiles.ets` | 459 | 拆分 | 本地文件、快照和云端文件处理混合 | 主包和测试 HAP 编译通过；CloudBackupFiles；云备份文件操作；真机待复测 |
| `entry/src/main/ets/common/constants/SettingsConstants.ets` | 452 | 保留 | 设置常量与值域定义 | 已审查，待最终复核 |
| `entry/src/main/ets/views/StorageView.ets` | 433 | 保留 | 单一存储统计展示页 | 已审查，待最终复核 |
| `entry/src/main/ets/service/sync/CloudStore.ets` | 428 | 保留 | 单一云端存储适配器 | 已审查，待最终复核 |
| `entry/src/main/ets/views/TranslateSettingsView.ets` | 424 | 保留 | 单一翻译配置表单 | 已审查，待最终复核 |
| `entry/src/main/ets/service/RemoteAccountStore.ets` | 415 | 拆分 | 账号、映射与发件箱存储混合 | 主包和测试 HAP 编译通过；RemoteOutboxStore；待同步发件箱 SQL；真机待复测 |
| `entry/src/main/ets/service/HttpClient.ets` | 411 | 保留 | 单一 HTTP 传输适配器 | 已审查，待最终复核 |

## 验证记录

- 29 项拆分均保留原入口和公开调用方式；新增模块复用原数据库连接与应用级单例。14 项保留文件逐项复核，职责仍集中于表结构、算法、协议、表单或单页展示；行数不是验收阈值。
- 主包与 `entry@ohosTest` HAP 编译通过；当前环境没有 `arkts_check` 命令，以 HAP ArkTS 编译覆盖语法和类型检查。
- 本轮完整 `ohosTest` 在 Mate 70 Pro 与模拟器均为 495/495；两台设备跑完测试 HAP 后均已重装主包。
- CodeLinter 最终只有既存的 `ResponsiveContent.ets:17` 一条性能建议；V2 扫描没有发现实际使用 V1 装饰器，命中项为 V2 `@BuilderParam` 或说明文字。
- Mate 70 Pro 万篇样本（500 源）完成五轮：列表 430、456、516、564、596 ms，中位 516 ms、最慢 596 ms；备份元数据 130、137、193、159、196 ms，中位 159 ms、最慢 196 ms。与此前同测试样本的优化版记录（列表中位 615 ms、备份中位 175 ms）相比，列表中位改善约 16.1%，但并非同一提交的前后对照，不能单独归因于职责拆分。搜索 CJK/FTS 结果断言通过。
- 同机五次冷启动的 HDC 主机往返计时为 227、247、250、196、284 ms（中位 247 ms、最慢 284 ms）；应用内首次内容帧为 364、346、343、355、370 ms（中位 355 ms、最慢 370 ms）。三秒帧采样的最差间隔为 172、40、29、26、24 ms；第一轮出现 172 ms 慢帧，后四轮未复现，仍需作为卡顿风险跟踪。HDC 往返时间与此前 AA 冷启动数据口径不同，不作回退百分比比较。
- 真机首页、订阅源和发现页已打开并截图核对；深链、长文切换、离线、同步冲突、通知去重、备份恢复、千篇 UI 滚动和内存峰值尚缺同数据的完整交互验收。设备当前用户库约百篇，万篇样本在测试独立数据库中，因此列表 SQL 性能不等于千篇 UI 滚动性能。
- 工作区还有其他正在进行的键盘套件、资源和构建配置改动；本次提交必须按文件区分，不能顺带暂存。
