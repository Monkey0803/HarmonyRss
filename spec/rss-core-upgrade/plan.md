# Implementation Plan: 本地内容规模与检索能力升级

**Input**: `spec/rss-core-upgrade/spec.md`

## Summary

在不引入账号与云端的前提下，把「本地文章」从 1000 篇上限升级为**可配置长期保留 + 可撤销清理**，
把「列表内关键词过滤」升级为**落库的全文检索 + 查询语法 + 搜索历史 + 命中定位**，
并把「全局抓取/保留/通知策略」升级为**单源覆盖 + 源健康状态**。
同时解决规模化的两个前置问题：**列表不再把正文全文读进内存**、**数据库迁移显式版本化**。

## Technical Context

**Language/Version**: ArkTS / HarmonyOS SDK（工程 `modelVersion` 6.1.0，API 23+ 能力按 `canIUse` / 能力探测降级）
**Primary Dependencies**: `@kit.ArkData`（relationalStore / preferences）、`@kit.ArkUI`、`@kit.BackgroundTasksKit`、`@kit.NotificationKit`、`@kit.UIDesignKit`（HDS）
**State Management**: 沿用现有 State Management V2（`@ObservedV2` + `@Trace`、`@ComponentV2` + `@Local`/`@Param`/`@Event`），不引入 V1
**Storage**: relationalStore（SQLite，`harmony_rss.db`）+ preferences（`hds_app_settings_v1`）
**Testing**: `entry/src/ohosTest`（hypium）+ `arkts_check` + `build_project`；注意测试 HAP 会覆盖主包，跑完需重装主包
**Target Platform**: HarmonyOS 手机 / 平板（现有 `deviceTypes`）
**Project Type**: mobile-app（单 entry 模块）
**Performance Goals**: 1 万篇规模下搜索首屏 < 300ms；冷启动到列表可交互 < 3s；清理不阻塞 UI
**Constraints**: 仅本地数据；纯 V2；HDS 组件约束；不得在 UI 线程做全库文本扫描
**Scale/Scope**: 1 万–5 万篇文章；数十个订阅源；新增 3 个页面、3 个服务、2 个 ViewModel

## Project Structure

### Documentation (this feature)

```text
spec/rss-core-upgrade/
├── spec.md
├── plan.md              # This file
└── tasks.md             # /spec-tasks output
```

### Source Code (repository root)

沿用现有 MVVM 分层（`common/` `model/` `service/` `viewmodel/` `views/` `pages/`），**不新增顶层目录、不做 MVVM 迁移**。

```text
entry/src/main/ets/
├── common/constants/
│   ├── RssConstants.ets            # 修改：移除条数上限，新增 FTS/Trash/搜索常量
│   ├── SettingsConstants.ets       # 修改：RetentionMode / RetentionDays / 三态枚举
│   ├── SettingsOptions.ets         # 修改：新增选项表
│   ├── PreferencesConstants.ets    # 修改：新增保留策略 / 搜索历史 key
│   └── RouterConstants.ets         # 修改：搜索 / 存储 / 源设置路由
├── model/
│   ├── Feed.ets                    # 修改：FeedSource 扩展 + EffectiveFeedSettings
│   ├── AppSettings.ets             # 修改：全局保留策略
│   └── Search.ets                  # 新增：SearchQuery / SearchHit / SearchPage / StorageStats
├── service/
│   ├── ArticleStore.ets            # 修改：版本化迁移、FTS、回收站、轻量列表、按需正文、统计
│   ├── RetentionService.ets        # 新增：候选计算 / 清理 / 恢复 / 过期清理
│   ├── SearchStore.ets             # 新增：FTS 查询与 LIKE 降级、搜索历史
│   ├── SearchQueryParser.ets       # 新增：查询语法解析（纯函数）
│   ├── FeedStore.ets               # 修改：持久化单源设置与健康状态
│   ├── SettingsStore.ets           # 修改：保留策略读写
│   ├── ArticleContentService.ets   # 修改：接收全文策略（auto/always/never）
│   └── BackgroundRefresh.ets       # 保持全局调度，源级到期由抓取编排判断
├── viewmodel/
│   ├── FeedViewModel.ets           # 修改：源级抓取门控、按需正文、清理触发、搜索定位
│   ├── SearchViewModel.ets         # 新增：搜索页状态与分页
│   ├── StorageViewModel.ets        # 新增：存储页统计与清理编排
│   └── SettingsViewModel.ets       # 修改：保留策略 setter
├── views/
│   ├── SearchView.ets              # 新增：全局搜索页
│   ├── StorageView.ets             # 新增：存储与保留页
│   ├── FeedSettingsView.ets        # 新增：单源设置页
│   ├── HomeTabView.ets             # 修改：搜索入口改为打开搜索页
│   ├── SubscriptionsView.ets       # 修改：源健康状态 + 「源设置」入口
│   ├── SettingsTabView.ets         # 修改：「存储与保留」入口
│   └── ArticleDetailView.ets       # 修改：搜索命中定位、滚动已读
├── pages/Index.ets                 # 修改：注册 3 个 NavDestination
└── workscheduler/RssWorkScheduler.ets  # 修改：源级到期 / 停用 / 通知过滤 / 清理

entry/src/main/resources/
├── base/element/string.json        # 新增英文文案
├── zh_CN/element/string.json       # 新增中文文案
└── base/element/float.json         # 复用现有尺寸，必要时新增
```

**Structure Decision**: 遵循现有工程架构（MVVM 责任边界已存在），不新建 `data/` 层，持久化继续放在 `service/`。新增文件按「一个页面一个 View + 一个 ViewModel / 一个领域一个 Service」拆分，避免把 `FeedViewModel`（已 1670 行）继续膨胀。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
| --------- | ---------- | ------------------------------------ |
| 新增 FTS 虚表 + 回收站表 | 1 万篇规模下的检索与可撤销清理 | 内存过滤 / 直接 DELETE 无法满足性能与可恢复性 |
| 列表与正文分表读取 | 去掉 1000 上限后全量加载会把 HTML 读进内存 | 只改上限会在数千篇时 OOM / 启动变慢 |

## Research & Decisions

### R-01 全文检索实现

- **Decision**: 使用 relationalStore 的 FTS5 虚表（`articles_fts`，列：`article_id UNINDEXED` / `title` / `summary` / `plain_text` / `author`），写入时同步；`StoreConfig.tokenizer` 优先 `ICU_TOKENIZER`，用 `relationalStore.isTokenizerSupported()` 探测，不支持时退回默认分词器。
- **Rationale**: 官方文档明确关系型数据库支持 FTS 场景并提供分词器配置；把检索下沉到 SQL 才能覆盖全库并满足 1 万篇首屏指标。
- **Alternatives considered**: 纯内存倒排索引（启动重建成本高、内存占用大）；`LIKE '%kw%'` 全表扫描（无法用索引、中文长文本慢）。

### R-02 中文检索兜底

- **Decision**: ICU 分词可用时走 `MATCH`；当查询包含 CJK 字符且 FTS 命中为 0 时，追加一次 `LIKE` 子串查询（结果去重、按时间排序）。
- **Rationale**: ICU 中文分词对单字 / 未登录词可能漏召回；`LIKE` 兜底保证「中文关键词可命中」的验收项。
- **Alternatives considered**: 仅依赖 `LIKE`（性能差）；自建二元组索引（维护成本高）。

### R-03 存储与迁移

- **Decision**: 使用 `RdbStore.version` 做显式迁移（v1 = 现有表；v2 = 索引 + FTS + 回收站）。保留现有 `addColumnIfNeeded` 兼容旧库；迁移在 `open()` 内按版本串行执行，失败则降级为「无缓存」启动并记录日志。
- **Rationale**: 现有代码靠 ALTER 试错，无法承载建虚表 / 建索引这类不可重复执行的结构变更。
- **Alternatives considered**: 继续 ALTER 试错（FTS 建表失败无法区分「已存在」与「真失败」）；删库重建（丢失用户已读与收藏）。

### R-04 列表内存模型

- **Decision**: `loadRecent()` 改为「轻量列表查询」：只取 `id/feed_id/feed_title/title/link/summary/published_at/is_read/is_starred/is_saved/progress/progress_ratio/image_url/author`；`content` / `content_html` / `reader_html` / `plain_text` / `page_etag` 通过 `loadBody(id)` 按需加载。打开文章前确保正文已加载；搜索命中项按 id 从库补全。
- **Rationale**: 去掉上限后，正文 HTML 是内存占用的主要来源；阅读详情本来就需要按需提取，延迟加载不改变交互。
- **Alternatives considered**: 保持全量加载（5k 篇即可能数十 MB，冷启动抖动）；分页加载列表（筛选/未读统计需要全量元数据，改动面过大）。

### R-05 保留策略与撤销

- **Decision**: 清理采用「先搬进 `articles_trash`，再从 `articles` 删除并同步删除 FTS 行」，保留 7 天；恢复即反向操作。保护条件：`is_starred=1` 或 `is_saved=1` 或存在高亮 或 是当前打开文章。
- **Rationale**: 直接删除无法满足「7 天可恢复」且难以统计；回收站表与主表同构，恢复逻辑简单。
- **Alternatives considered**: 软删除标记位（所有查询都要加条件，易漏）；备份整库文件（体积大、粒度粗）。

### R-06 清理触发时机

- **Decision**: 三类触发：抓取提交后（异步、最小间隔 6 小时）、后台任务结束后、用户在存储页手动触发；启动时若有超期回收站条目则清理。全部异步执行，不阻塞 `publish`。
- **Rationale**: 满足「低优先级后台执行」与「存储页可立即清理」。
- **Alternatives considered**: 每次抓取都清理（频繁 IO）；仅手动（用户不会主动维护）。

### R-07 单源抓取门控

- **Decision**: `FeedSource` 增加 `enabled`、`fetchIntervalMinutes`（0 = 跟随全局）、`fullTextMode`、`retentionDays`（0 = 跟随全局）、`notify`（三态）、`markReadOnScroll`（三态）、`failureCount`；`lastUpdated` 语义明确为「最近成功时间」。抓取编排按「启用 + 到期」过滤，下拉刷新传 `force=true` 绕过到期判断（但不绕过停用）。
- **Rationale**: 与现有 `autoRefresh` 全局间隔兼容，源级只做覆盖，不改变后台任务注册模型。
- **Alternatives considered**: 为每个源注册独立 WorkScheduler 任务（系统任务数量与调度不可控）。

### R-08 搜索页与命中定位

- **Decision**: 首页放大镜改为压入独立搜索页（`PAGE_SEARCH`），移除列表内关键词输入；点击结果写 `FeedViewModel.pendingSearchTerm` 后打开详情页，详情页在正文加载完成后复用现有 `ReaderFind` 的 `findSupportScript` + `runFindScript` 定位首个命中并展开查找条。
- **Rationale**: 复用已存在的页内查找能力，避免另写一套 Web 注入；全局搜索与列表筛选职责分离。
- **Alternatives considered**: 保留列表内搜索（只能搜已加载页）；自写滚动定位脚本（重复实现且易碎）。

### R-09 滚动已读

- **Decision**: 当生效设置为「滚动已读」时，`openArticle` 不再立即标记已读；详情页在进度回调中当 `progressRatio ≥ 0.8` 或触底时调用 `markFinished`。
- **Rationale**: 现有行为是打开即已读，直接加字段无意义；进度桥接已经存在，改动可控。
- **Alternatives considered**: 不做该项（与 TODO 验收不符）。

### R-10 搜索历史存储

- **Decision**: 使用 preferences 的新 key 存 JSON 字符串数组（最多 20 条，去重、最新在前），读写失败静默降级。
- **Rationale**: 与现有设置存储一致，无需新建表。
- **Alternatives considered**: 建 SQLite 表（为 20 条数据过度设计）。

### R-11 降级与回滚

- **Decision**: FTS 建表或查询失败时自动降级为分页 `LIKE` 查询；数据库迁移失败不删库，以「无缓存」模式启动并在下次启动重试；保留清理可按回收站恢复。
- **Rationale**: 三个高风险点都必须有可用退路，避免升级导致功能不可用或数据不可挽回。
- **Alternatives considered**: 迁移失败即清库重建（丢用户状态）；FTS 失败即禁用搜索（功能缺失）。

## Data Model

### 数据库（`harmony_rss.db`，version 1 → 2）

**新增索引**

- `idx_articles_feed_published` on `articles(feed_id, published_at DESC)`
- `idx_articles_read` on `articles(is_read)`
- `idx_articles_starred` on `articles(is_starred)`
- `idx_highlights_article` on `highlights(article_id)`

**新增 FTS 虚表 `articles_fts`**

| 列 | 类型 | 说明 |
| --- | --- | --- |
| rowid | 隐式 | FTS 主键 |
| article_id | UNINDEXED | 对应 `articles.id` |
| title | 文本 | 标题 |
| summary | 文本 | 摘要 |
| plain_text | 文本 | 提取后的正文纯文本 |
| author | 文本 | 作者 |

同步规则：`insertNew` 批量插入；`setReaderHtml` 更新对应行；`deleteMany` / `deleteByFeed` / 保留清理同步删除；提供全量重建。

**新增回收站表 `articles_trash`**

与 `articles` 同构列 + `deleted_at INTEGER`，`id` 为主键。写入/恢复使用事务。

### 领域模型

**FeedSource（扩展）**

| 字段 | 类型 | 默认 | 语义 |
| --- | --- | --- | --- |
| enabled | boolean | true | 是否参与自动抓取与通知 |
| fetchIntervalMinutes | number | 0 | 0 = 跟随全局 |
| fullTextMode | string | 'global' | global / auto / always / never |
| retentionDays | number | 0 | 0 = 跟随全局 |
| notify | string | 'global' | global / on / off |
| markReadOnScroll | string | 'global' | global / on / off |
| failureCount | number | 0 | 连续失败次数（成功清零） |
| lastUpdated | number | 0 | 最近成功抓取时间（现有字段，明确语义） |

**AppSettings（扩展）**

- `retentionMode`: `'forever' | 'days' | 'unread'`（默认 `forever`）
- `retentionDays`: `'30' | '90' | '365'`（默认 `'90'`，仅 `days` 模式生效）

**Search（新增）**

- `SearchQuery`: `terms: string[]`、`phrase: string`、`from: string`、`state: string`（all/unread/read/starred/saved）、`after: number`、`before: number`
- `SearchHit`: `articleId`、`title`、`snippet`、`feedTitle`、`publishedAt`、`read`、`starred`、`saved`
- `SearchPage`: `hits: SearchHit[]`、`total: number`、`hasMore: boolean`

**StorageStats（新增）**

- `articleCount`、`textBytes`、`perFeed: FeedStorageStat[]`（`feedId` / `title` / `count` / `bytes`）、`cleanableCount`、`trashCount`

**EffectiveFeedSettings（新增，计算属性）**

由「全局设置 + 源覆盖」推导：`intervalMinutes`、`fullTextMode`、`retentionDays`、`notifyEnabled`、`markReadOnScroll`、`enabled`。

### 状态与迁移

- 旧 `FeedRecord` 缺失新字段 → 使用默认值（不丢源、不误停用）。
- 旧 `AppSettings` 无保留字段 → `forever`（绝不因为升级而删历史）。
- 回收站超过 7 天在启动与清理时清除。

## Contracts & Interfaces

### ArticleStore（扩展）

- `open(context)`：版本化迁移（索引 / FTS / 回收站），失败降级。
- `loadForList(): Promise<Article[]>`：轻量列，按 `published_at DESC`。
- `loadBody(id: string): Promise<ArticleBody | undefined>`：正文相关列（content / contentHtml / readerHtml / plainText / etag）。
- `isFtsReady(): boolean`
- `search(query: SearchQuery, offset: number, limit: number): Promise<SearchPage>`
- `rebuildSearchIndex(onProgress: (done: number, total: number) => void): Promise<void>`
- `retentionCandidates(mode: string, days: number): Promise<RetentionCandidate[]>`：返回 id / feedId / publishedAt，已排除受保护文章。
- `archiveToTrash(ids: string[]): Promise<number>`：事务内搬移 + 删 FTS。
- `restoreTrash(ids: string[]): Promise<number>`：事务内搬回 + 建 FTS。
- `purgeTrash(beforeTs: number): Promise<number>`
- `trashCount(): Promise<number>`
- `storageStats(): Promise<StorageStats>`
- `deleteMany` / `deleteByFeed`：同步删除 FTS 行（回收站不收录手动删除）。

### RetentionService（新增）

- `effectiveRetentionDays(feed: FeedSource | undefined): number`（0 表示永久）
- `estimate(): Promise<number>`：当前设置下可清理条数。
- `runIfDue(): Promise<number>`：按 6 小时节流执行。
- `runNow(): Promise<number>`：手动执行。
- `restoreAll(): Promise<number>`
- `purgeExpired(): Promise<number>`

### SearchQueryParser（新增，纯函数）

- `parse(raw: string): SearchQuery`
- `emptyQuery(raw: string): boolean`
- `escapeFtsToken(term: string): string`

### SearchStore（新增）

- `search(query: SearchQuery, offset: number, limit: number): Promise<SearchPage>`
- `history(): string[]` / `pushHistory(raw: string)` / `clearHistory()`

### FeedViewModel（扩展）

- `refreshAll(force: boolean)`（默认 `false`；下拉刷新传 `true`）
- `refreshCurrentFeed(force: boolean)`
- `effectiveSettings(feedId: string): EffectiveFeedSettings`
- `markReadOnScrollEffective(feedId: string): boolean`
- `ensureBodyLoaded(articleId: string): Promise<boolean>`
- `openSearchHit(articleId: string, term: string)`：补全正文、设置 `pendingSearchTerm`、打开详情
- `pendingSearchTerm: string`（详情页消费后清空）
- `openFeedSettings(feed: FeedSource)` / `settingsFeedId: string`
- `updateFeedSettings(feedId, patch)`：归一 → 内存 → `feedStore.save`
- `retryFeed(feedId: string): Promise<void>`
- `applyRetentionIfDue(): Promise<void>`

### 路由与页面契约

| 路由 | 页面 | 入口 |
| --- | --- | --- |
| `PAGE_SEARCH` = `search` | `SearchView` | 首页放大镜 |
| `PAGE_STORAGE` = `storage` | `StorageView` | 设置 → 存储与保留 |
| `PAGE_FEED_SETTINGS` = `feedSettings` | `FeedSettingsView` | 订阅源溢出菜单「源设置」 |

- `SearchView`：输入框、历史 chips、状态 chips（全部/未读/收藏）、结果列表（标题 + 来源 + 时间 + 命中片段）、触底续页、清空历史。
- `StorageView`：全局保留模式/天数选择、总条数与文本占用、按源占用列表（前 N + 展开）、可清理条数、立即清理（二次确认）、回收站条数与恢复、重建索引（进度提示）。
- `FeedSettingsView`：启用抓取、抓取间隔（跟随全局/15/30/60/180）、全文策略（跟随全局/自动/总是/从不）、保留天数（跟随全局/30/90/365/永久）、通知（跟随全局/开/关）、滚动已读（跟随全局/开/关）、健康信息与手动重试。

### 资源契约

- 所有新增文案同时写入 `base/element/string.json`（英文）与 `zh_CN/element/string.json`（中文），key 统一前缀：`search_*`、`storage_*`、`feed_settings_*`、`retention_*`、`health_*`。
- 不新增颜色；尺寸优先复用现有 `float`。
