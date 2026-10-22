# Implementation Plan: FreshRSS 兼容服务接入（Google Reader API）

**Input**: `spec/freshrss-client/spec.md`

## Summary

新增「远端账号」能力：用户填写自建服务地址与账密，应用通过 Google Reader API 拉取订阅与文章、
双向同步已读/收藏。远端文章复用现有 `articles` 表与检索索引，新增映射表、待同步队列与同步游标；
凭据存入 Asset Store（HUKS 护航），不进偏好与日志；启用后与本地订阅按地址合并，本地仍是离线权威副本。

## Technical Context

**Language/Version**: ArkTS / HarmonyOS SDK（工程 modelVersion 6.1.0，API 23+）
**Primary Dependencies**: `@kit.NetworkKit`（http）、`@kit.AssetStoreKit`（凭据）、`@kit.ArkData`（relationalStore）、`@kit.ArkUI`、`@kit.UIDesignKit`
**State Management**: 沿用 State Management V2
**Storage**: relationalStore（schema v4 → v5）+ Asset Store（密码）
**Testing**: `entry/src/ohosTest`（hypium）+ `arkts_check` + `build_project`；协议层用 Mock HTTP 纯逻辑测试
**Target Platform**: HarmonyOS 手机 / 平板
**Project Type**: mobile-app（单 entry 模块）
**Performance Goals**: 连接 < 5s；首次同步 500 篇 < 30s；50 条状态回写 < 5s；二次无新增 < 3s
**Constraints**: 仅 Google Reader API；单账号；账密登录；允许 http（需明文配置）；失败不阻塞本地
**Scale/Scope**: 单账号、≤200 个远端订阅、单次同步 ≤2000 篇；新增 1 张账号表、2 张同步表、1 张映射表

## Project Structure

### Documentation (this feature)

```text
spec/freshrss-client/
├── spec.md
├── plan.md              # This file
└── tasks.md
```

### Source Code (repository root)

沿用现有 MVVM 分层：

```text
entry/src/main/ets/
├── model/
│   └── Remote.ets                    # 新增：RemoteAccount / RemoteFeed / RemoteArticle / SyncStatus / OutboxItem
├── common/constants/
│   ├── RssConstants.ets              # 修改：SCHEMA_VERSION 4→5；远端表名与同步常量
│   ├── PreferencesConstants.ets      # 修改：远端自动同步开关 / 间隔 key
│   └── RouterConstants.ets           # 修改：PAGE_REMOTE
├── service/
│   ├── remote/
│   │   ├── GReaderClient.ets         # 新增：HTTP 封装（ClientLogin / subscription / contents / items ids / edit-tag / token）
│   │   ├── GReaderModels.ets         # 新增：协议 DTO 与 JSON 解析
│   │   ├── RemoteCredentials.ets     # 新增：Asset Store 读写密码
│   │   └── RemoteSyncService.ets     # 新增：同步编排（订阅合并 / 增量拉取 / 状态双向 / 队列）
│   ├── RemoteAccountStore.ets        # 新增：账号、游标、映射、待同步队列的 SQL
│   ├── ArticleStore.ets              # 修改：v5 建表；批量插入远端文章；按 remote_id 查映射；状态更新
│   └── ArticleMapper.ets             # 复用：buildArticleId 统一本地 id
├── viewmodel/
│   ├── RemoteAccountViewModel.ets     # 新增：表单 / 测试连接 / 同步状态 / 退出登录
│   └── FeedViewModel.ets             # 修改：已读/收藏变更入待同步队列
├── views/
│   └── RemoteServiceView.ets         # 新增：账号与服务页（表单 + 状态 + 同步 + 退出）
├── views/SettingsTabView.ets         # 修改：新增「账号与服务」入口
└── pages/Index.ets                   # 修改：注册 PAGE_REMOTE；回前台触发自动同步

entry/src/main/resources/
├── base/profile/network_config.json  # 新增：允许明文 http（配合用户显式开关的说明）
├── base/element/string.json          # 新增 remote_* 文案（英文）
└── zh_CN/element/string.json         # 新增 remote_* 文案（中文）

entry/src/ohosTest/ets/test/
├── GReaderModels.test.ets            # 新增：JSON 解析 / 错误映射 / 订阅 id 解析
└── RemoteSyncPlan.test.ets           # 新增：合并策略 / 冲突决策 / 队列聚合（纯函数）
```

**Structure Decision**: 遵循现有工程架构；协议与编排单独放 `service/remote/`，数据库结构仍由 `ArticleStore.migrate()` 统一创建。凭据只走 Asset Store，不新增明文存储。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
| --------- | ---------- | ------------------------------------ |
| `service/remote/` 子目录 | 协议 DTO、HTTP、凭据、同步编排四类职责，混放难以维护与测试 | 全塞进单个 Service：文件过大、无法单测协议解析 |
| 映射表 + 待同步队列 | 远端 id 与本地 id 不同构，且离线需要补发状态 | 直接在 articles 存 remote_id：无法支持后续多账号；无队列会丢离线变更 |

## Research & Decisions

### R-01 认证方式（ClientLogin）

- **Decision**: 使用 Google Reader 的 ClientLogin：`POST {base}/accounts/ClientLogin`（表单 `Email` / `Passwd`），从响应文本解析 `Auth=`，后续请求带 `Authorization: GoogleLogin auth=<Auth>`；写操作前调用 `{base}/reader/api/0/token` 取 `T` 并随表单提交。
- **Rationale**: FreshRSS / TTRSS / Miniflux 的 GReader 兼容层均支持该路径，无需 OAuth 回调与浏览器。
- **Alternatives considered**: OAuth2（FreshRSS 不支持、需服务端配置）；API Token（各家格式不同）。

### R-02 Base URL 归一与探测

- **Decision**: 用户输入主机（可带端口与路径）。若路径为空或 `/`，自动补 `/api/greader.php`；随后依次尝试 `accounts/ClientLogin` + `reader/api/0/subscription/list`。支持 http 与 https。
- **Rationale**: FreshRSS 常见部署形态差异大；一次探测可覆盖「只填域名」「填完整 API 路径」「反代子路径」三类。
- **Alternatives considered**: 只接受完整路径（用户配置成本高）；多套服务各自硬编码（无法覆盖自建）。

### R-03 凭据存储

- **Decision**: 密码写入 Asset Store（`asset.add`），`ALIAS = rss_remote_<accountId>`，`ACCESSIBILITY = DEVICE_FIRST_UNLOCKED`；读取用 `asset.query`；退出登录 `asset.remove`。数据库只存地址、用户名、状态。
- **Rationale**: 官方明确 Asset Store 适合账号/密码/Token，底层由 HUKS 管理；避免 Preferences 明文。
- **Alternatives considered**: Preferences（root/备份可读）；自建 AES + 密钥硬编码（等于没加密）。

### R-04 明文 HTTP

- **Decision**: 新增 `resources/base/profile/network_config.json`，`base-config.cleartextTrafficPermitted = true`；连接页提供「允许 http」开关与风险说明；关闭时连接 http 地址直接拒绝并提示。
- **Rationale**: API 23 起默认拦截明文；自建实例常无证书。开关让用户在知情前提下选择。
- **Alternatives considered**: 全局禁用 http（挡住大量自建用户）；按域名白名单（配置静态，无法覆盖用户任意地址）。

### R-05 本地 id 与远端 id 映射

- **Decision**: 远端文章复用 `ArticleMapper.buildArticleId(feedId, item)` 生成本地 id（与本地抓取一致，天然去重）；新增 `remote_article_map(remote_id PK, article_id, feed_id, updated_at)` 记录远端 id → 本地 id。若本地已存在同 link 的文章（本地 id 相同），只补映射，不重复插入。
- **Rationale**: 保持列表/检索/保留策略不变；映射表为回写状态提供远端 id。
- **Alternatives considered**: 直接在 `articles` 加 `remote_id` 列（单账号可用，但多账号/多服务受限）；用 link 反查映射（link 可能为空）。

### R-06 增量拉取与游标

- **Decision**: 每个远端订阅按 `stream/contents` 分页拉取（`n=100`，`c=continuation`），最多 10 页/源；遇到 `published < cursor(feed)` 停止并翻页。`sync_state` 存每源 `cursor_<feedId>` 与 `last_sync_at`。首次同步每源只取最新 100 篇，避免一次性拉爆。
- **Rationale**: 不依赖 `ot/nt` 的厂商差异；用发布时间 + 分页即可增量。
- **Alternatives considered**: 只取首页（>100 篇/同步间隔时漏文章）；依赖 `ot`（部分实现语义不一致）。

### R-07 状态双向同步与冲突

- **Decision**: 每次同步顺序为「先 push 本地 outbox，再拉远端状态」。
  - push：`sync_outbox` 按文章聚合（set_read/read_value、set_starred/starred_value），每批 50 条调用 `edit-tag`；
  - pull：分页取「未读 id 集合」与「收藏 id 集合」，对已映射文章计算目标状态，只更新与本地不同且不在 outbox 中的字段。
  - 冲突：本地未推送的变更优先（push-first）；已推送后以远端返回为准；进度字段不参与远端同步，保留本地值。
- **Rationale**: GReader 状态接口没有可靠的「最后修改时间」，push-first 是确定性且符合「最近修改优先」的实现。
- **Alternatives considered**: 拉取优先（本地刚标记的已读会被远端旧状态覆盖）；双向时间戳（协议不提供）。

### R-08 文章入库与索引

- **Decision**: 远端文章转换为 `Article` 后走现有 `articleStore.insertNew`（同步写主 FTS 与中文索引），正文留空、打开时再提取；单次同步总量上限 2000 篇，超出留待下次。
- **Rationale**: 复用离线与检索能力，不引入第二套存储。
- **Alternatives considered**: 远端正文直接入库（体积大、质量不可控）；只存远端 id（离线不可读）。

### R-09 同步触发

- **Decision**: 手动同步（账号页按钮）+ 连接成功后自动同步一次 + 回前台按「自动同步间隔」判断（复用现有 `autoRefresh` 档位，默认关闭）。后台 WorkScheduler 留到后续批次。
- **Rationale**: 先保证前台链路正确，避免后台与界面并发写同一队列。
- **Alternatives considered**: 直接接后台任务（调试成本高、并发冲突多）。

### R-10 失败降级与可观测

- **Decision**: 所有同步错误分类记录（网络 / 证书 / 凭据 / API 未开启 / 限流 / 服务端），账号页显示最后成功时间、待同步条数、连续失败次数与最近错误；同步失败不改变本地数据。
- **Rationale**: 满足「失败不阻塞阅读」与可诊断要求。
- **Alternatives considered**: 仅 Toast（用户无法回看原因）。

### R-11 风险与回滚

- **协议差异**: 不同服务的 `stream/contents` 字段略有差异，解析层必须容错（缺字段给默认值）。
- **明文 http**: 全局配置放开，需在连接页明确风险提示。
- **首次同步量**: 单源 ≤100 篇、单次总量 ≤2000 篇；超出留待下次并显示进度。
- **回滚**: 同步失败只记录，不改本地；账号表与映射表可整体删除，不影响已有文章。

## Data Model

### 数据库（`harmony_rss.db`，v4 → v5）

**`remote_accounts`**

| 列 | 类型 | 说明 |
| --- | --- | --- |
| id | TEXT PK | `ra_<ts>_<rand>` |
| base_url | TEXT | 归一后的 API 基地址 |
| username | TEXT | 账号 |
| service_type | TEXT | `greader` |
| enabled | INTEGER | 是否启用同步 |
| created_at / updated_at | INTEGER | 毫秒 |

**`sync_state`**

| 列 | 类型 | 说明 |
| --- | --- | --- |
| key | TEXT PK | `last_sync_at` / `cursor_<feedId>` / `state_sync_at` |
| value | TEXT | 字符串值 |

**`remote_article_map`**

| 列 | 类型 | 说明 |
| --- | --- | --- |
| remote_id | TEXT PK | 远端 item id |
| article_id | TEXT | 本地文章 id |
| feed_id | TEXT | 本地订阅 id |
| updated_at | INTEGER | 映射更新时间 |

索引：`idx_remote_map_article ON remote_article_map(article_id)`。

**`sync_outbox`**

| 列 | 类型 | 说明 |
| --- | --- | --- |
| article_id | TEXT PK | 本地文章 id（同篇聚合） |
| set_read / read_value | INTEGER | 是否需要回写已读及其值 |
| set_starred / starred_value | INTEGER | 是否需要回写收藏及其值 |
| updated_at | INTEGER | 最近一次本地变更时间 |
| retries | INTEGER | 连续失败次数 |
| last_error | TEXT | 最近错误（可诊断） |

### 领域模型（`model/Remote.ets`）

- `RemoteAccount`：id / baseUrl / username / serviceType / enabled / lastSyncAt / pendingCount / failureCount / lastError。
- `RemoteFeed`：remoteId / url / title / group。
- `RemoteArticle`：remoteId / feedUrl / title / link / summary / content / publishedAt / author / read / starred。
- `SyncStatus`：lastSyncAt / pending / failures / lastError / phase。
- `SyncResult`：feedsAdded / articlesAdded / statesPushed / statesPulled / errors。

## Contracts & Interfaces

### GReaderClient（新增）

- `login(baseUrl, username, password): Promise<string>`：返回 auth token，失败抛出分类错误。
- `fetchSubscriptions(auth): Promise<RemoteFeed[]>`
- `fetchContents(auth, feedUrl, continuation, limit): Promise<RemoteContentsPage>`（含 `items` / `continuation`）
- `fetchUnreadIds(auth, continuation?): Promise<IdPage>`
- `fetchStarredIds(auth, continuation?): Promise<IdPage>`
- `fetchWriteToken(auth): Promise<string>`
- `editTag(auth, writeToken, remoteId, addTags, removeTags): Promise<void>`
- `probe(baseUrl): Promise<ProbeResult>`：尝试补全路径与 API 可用性。
- 错误类型：`RemoteErrorCode`（NETWORK / TLS / AUTH / API_DISABLED / RATE_LIMIT / SERVER / PARSE）。

### RemoteCredentials（新增）

- `save(accountId, password): Promise<void>`
- `read(accountId): Promise<string | undefined>`
- `remove(accountId): Promise<void>`

### RemoteAccountStore（新增）

- `loadAccount(): Promise<RemoteAccount | undefined>`（单账号）
- `saveAccount(account): Promise<void>`
- `clearAccount(): Promise<void>`
- `getState(key): Promise<string>` / `setState(key, value): Promise<void>`
- `mapRemote(remoteId, articleId, feedId): void` / `articleIdOf(remoteId): Promise<string | undefined>` / `remoteIdOf(articleId)`
- `enqueueState(articleId, read?, starred?): void`（聚合写）
- `pendingItems(limit): Promise<OutboxItem[]>` / `ackItems(ids)` / `failItem(id, error)`
- `pendingCount(): Promise<number>`

### RemoteSyncService（新增）

- `connect(baseUrl, username, password, allowHttp): Promise<ConnectResult>`：探测 → 登录 → 存凭据 → 存账号 → 首次同步。
- `syncNow(): Promise<SyncResult>`
- `maybeAutoSync(): void`：回前台按间隔判断。
- `logout(clearLocal: boolean): Promise<void>`
- `status(): Promise<SyncStatus>`
- 纯逻辑辅助（可单测）：`mergeFeeds(local, remote)`、`decideState(local, remote, outbox)`、`buildEditTagBatches(items)`。

### ArticleStore（扩展）

- `migrate()` v5：建 4 张表 + 索引（可重复执行、失败降级）。
- `insertRemote(articles: Article[], mappings: RemoteMapping[]): Promise<number>`：事务内插文章 + 映射 + 双索引；已存在 link 时只补映射。
- `setReadByRemote` / `setStarredByRemote`：仅更新状态列，不触碰正文/进度。

### FeedViewModel（扩展）

- 在 `toggleRead` / `markReadMany` / `toggleStar` / `markStarredMany` / `markFinished` 后调用
  `remoteSyncService.enqueueState(articleId, ...)`（未连接账号时内部直接返回）。

### 路由与页面契约

| 路由 | 页面 | 入口 |
| --- | --- | --- |
| `PAGE_REMOTE` = `remoteService` | `RemoteServiceView` | 设置 → 账号与服务 |

- 表单：服务地址、用户名、密码（Password 输入）、允许 http 开关、连接按钮。
- 状态卡：服务类型、最后同步、待同步条数、连续失败、最近错误、立即同步、退出登录（含「同时清除本地数据」二次确认）。
- 同步中显示进度文案（拉取订阅 / 拉取文章 / 回写状态）。

### 资源与平台配置

- `network_config.json`：`network-security-config.base-config.cleartextTrafficPermitted = true`。
- 文案 key 前缀 `remote_*`，中英成对。
- 不新增权限（INTERNET 已有）。
