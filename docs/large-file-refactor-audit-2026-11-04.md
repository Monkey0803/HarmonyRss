# 长文件职责审查与实施记录

快照日期：2026-11-04。范围：`entry/src/main/ets` 中超过 400 行的 `.ets` 文件。行数是定位线索，不是拆分验收条件。

| 文件 | 行数 | 结论 | 职责依据 | 验证状态 |
| --- | ---: | --- | --- | --- |
| `entry/src/main/ets/views/ArticleDetailView.ets` | 3518 | 拆分 | 阅读会话、进度、查找、媒体与页面状态混合 | 待实施 |
| `entry/src/main/ets/viewmodel/FeedViewModel.ets` | 2356 | 拆分 | 抓取、列表投影、订阅管理和阅读操作混合 | 批次 1 进行中 |
| `entry/src/main/ets/service/ArticleRepository.ets` | 1860 | 拆分 | 备份、去重、回收站和文章查询混合 | 批次 1 进行中 |
| `entry/src/main/ets/service/sync/SyncCollector.ets` | 1193 | 拆分 | 多种记录的采集与应用集中在一类 | 待实施 |
| `entry/src/main/ets/views/DiscoverView.ets` | 1022 | 拆分 | 发现列表、RSSHub、预览和导入交互混合 | 待实施 |
| `entry/src/main/ets/service/remote/RemoteSyncService.ets` | 933 | 拆分 | 拉取、推送、迁移及账号状态编排混合 | 待实施 |
| `entry/src/main/ets/pages/Index.ets` | 885 | 拆分 | 导航、深链、响应式布局及页签状态混合 | 待实施 |
| `entry/src/main/ets/views/SubscriptionsView.ets` | 767 | 拆分 | 列表行状态展示、编辑和页面编排混合 | 批次 1 进行中 |
| `entry/src/main/ets/views/BackupView.ets` | 740 | 拆分 | 本地与云端备份流程及页面展示混合 | 待实施 |
| `entry/src/main/ets/service/SettingsStore.ets` | 730 | 拆分 | 偏好读写、备份白名单和站点偏好混合 | 待实施 |
| `entry/src/main/ets/model/Sync.ets` | 716 | 拆分 | 同步载荷模型、编解码与合并规则混合 | 待实施 |
| `entry/src/main/ets/views/HomeTabView.ets` | 707 | 拆分 | 首页列表、空态、批量操作和面板混合 | 批次 1 进行中 |
| `entry/src/main/ets/service/BackupService.ets` | 688 | 拆分 | 本地、云端、快照及导入恢复流程混合 | 待实施 |
| `entry/src/main/ets/service/MediaPlayerService.ets` | 643 | 拆分 | 播放队列、系统会话和进度持久化混合 | 待实施 |
| `entry/src/main/ets/views/NotifySettingsView.ets` | 640 | 拆分 | 权限、策略、免打扰及摘要设置混合 | 待实施 |
| `entry/src/main/ets/service/TagStore.ets` | 629 | 拆分 | 标签定义、关联、统计和备份搬运混合 | 待实施 |
| `entry/src/main/ets/service/ArticleSearchStore.ets` | 625 | 保留 | 单一全文检索领域实现 | 已审查，待最终复核 |
| `entry/src/main/ets/service/SyncService.ets` | 601 | 拆分 | 同步开关、后端选择、执行和重试混合 | 待实施 |
| `entry/src/main/ets/views/ShareSheet.ets` | 568 | 拆分 | 分享动作、模板和导出面板混合 | 待实施 |
| `entry/src/main/ets/service/RuleStore.ets` | 558 | 拆分 | 规则 CRUD、命中统计和备份搬运混合 | 待实施 |
| `entry/src/main/ets/service/ArticleDatabase.ets` | 554 | 拆分 | 共享连接、结构修复和索引生命周期混合 | 批次 1 进行中 |
| `entry/src/main/ets/service/BackupCodec.ets` | 546 | 拆分 | 序列化、校验、白名单和合并策略混合 | 待实施 |
| `entry/src/main/ets/service/Readability.ets` | 540 | 保留 | 单一正文提取算法 | 已审查，待最终复核 |
| `entry/src/main/ets/views/SearchView.ets` | 533 | 拆分 | 搜索结果与智能文件夹保存流程混合 | 待实施 |
| `entry/src/main/ets/service/RssParser.ets` | 526 | 保留 | 单一 Feed 解析算法 | 已审查，待最终复核 |
| `entry/src/main/ets/views/SyncView.ets` | 524 | 拆分 | 同步状态、后端设置和重置流程混合 | 待实施 |
| `entry/src/main/ets/views/RuleEditView.ets` | 519 | 保留 | 单一规则表单 | 已审查，待最终复核 |
| `entry/src/main/ets/service/ArticleSchema.ets` | 510 | 保留 | 共享表结构及 SQL 定义 | 已审查，待最终复核 |
| `entry/src/main/ets/service/ArticleContentService.ets` | 509 | 拆分 | 正文抓取、提取、图片内联与缓存落库混合 | 待实施 |
| `entry/src/main/ets/views/DiagnosticsView.ets` | 506 | 保留 | 单一诊断展示页 | 已审查，待最终复核 |
| `entry/src/main/ets/views/AddFeedPanel.ets` | 495 | 拆分 | 地址输入、预览和批量添加阶段混合 | 待实施 |
| `entry/src/main/ets/service/HtmlSanitizer.ets` | 480 | 保留 | 单一 HTML 净化算法 | 已审查，待最终复核 |
| `entry/src/main/ets/views/RemoteServiceView.ets` | 477 | 保留 | 单一远端账号设置页 | 已审查，待最终复核 |
| `entry/src/main/ets/service/ReaderSpeech.ets` | 475 | 保留 | 单一语音播放生命周期 | 已审查，待最终复核 |
| `entry/src/main/ets/views/ShareSettingsView.ets` | 474 | 拆分 | 模板列表管理与编辑表单混合 | 待实施 |
| `entry/src/main/ets/service/NotifyService.ets` | 468 | 拆分 | 通知聚合策略、排队与系统发布混合 | 待实施 |
| `entry/src/main/ets/service/BackupFiles.ets` | 459 | 拆分 | 本地文件、快照和云端文件处理混合 | 待实施 |
| `entry/src/main/ets/common/constants/SettingsConstants.ets` | 452 | 保留 | 设置常量与值域定义 | 已审查，待最终复核 |
| `entry/src/main/ets/views/StorageView.ets` | 433 | 保留 | 单一存储统计展示页 | 已审查，待最终复核 |
| `entry/src/main/ets/service/sync/CloudStore.ets` | 428 | 保留 | 单一云端存储适配器 | 已审查，待最终复核 |
| `entry/src/main/ets/views/TranslateSettingsView.ets` | 424 | 保留 | 单一翻译配置表单 | 已审查，待最终复核 |
| `entry/src/main/ets/service/RemoteAccountStore.ets` | 415 | 拆分 | 账号、映射与发件箱存储混合 | 待实施 |
| `entry/src/main/ets/service/HttpClient.ets` | 411 | 保留 | 单一 HTTP 传输适配器 | 已审查，待最终复核 |

## 验证记录

- 批次 1：数据库结构修复、文章备份与去重组查询、列表筛选和分组投影已抽出；主包构建通过，模拟设备完整 `ohosTest` 493/493 通过，CodeLinter 仅有既存的 `ResponsiveContent.ets:17` 提示。
- Mate 70 Pro 当前未出现在 `hdc list targets`；真机五次性能复测与页面全流程验收待连接后执行。
- 工作区另有已暂存的 Toast/发现页改动；本批提交不得包含这些无关改动。
