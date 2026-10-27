# Implementation Plan: 远端订阅迁移 / 服务模式

## Source Changes

- 新增 `RemoteMigrationMode` / `RemoteMigrationPreview` / `RemoteMigrationResult`；
  `RemoteConnectResult` 增加 `localOnlyCount` / `needsMigration`；`RemoteErrorCode.SUBSCRIPTION_FAILED`。
- `RemoteBackend` 新增 `subscribeFeed`：
  - `GReaderClient.subscribe`：`POST /reader/api/0/subscription/edit`（ac=subscribe + write token）；
  - `FeedbinBackend.subscribeFeed`：`POST /subscriptions.json`，300 多选取第一个 `feed_url`。
- `RemoteSyncService`：
  - `subscriptionMode()` / `previewMigration()` / `applyMigration()`；
  - `subscription_mode` 与 `mode_disabled_feeds` 存 `sync_state`（无需 DB 迁移）；
  - `runSync` 在 remoteOnly 模式下强制停用本地独有源，并在远端已有时自动恢复。
- `RemoteSyncPlan.localOnlyFeeds` 抽成纯函数便于单测。
- 新增 `views/RemoteMigrationView.ets` + 路由；账号页展示模式 / 迁移入口 / 连接后提示。
- 测试：`RemoteSyncPlan.test` 增加 localOnly 用例，`FeedbinModels.test` 增加 300 候选解析。

## Decisions

- **模式存账号级 sync_state**：避免新增表 / 迁移；切换服务或地址会清空旧模式。
- **仅远端 = 停用而非删除**：保留历史与用户数据；记录「本次因模式停用」的 id，切回时只恢复这些。
- **迁入失败不切模式**：保证模式语义可靠；重复订阅由 GReader / Feedbin 的幂等行为兜底。
- **迁移不自动全量同步**：只做订阅层变更，文章同步仍走既有 syncNow / 自动同步。
