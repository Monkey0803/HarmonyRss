# Feature Specification: 远端服务适配层 + Feedbin

**Created**: 2026-10-26
**Status**: Implemented
**Input**: `TODO.md` P0-2 第二批。

## Overview

把原先直接写在 `RemoteSyncService` 里的 Google Reader 协议细节抽成 `RemoteBackend` 适配层，
并新增 **Feedbin**（REST + HTTP Basic Auth）后端。同步编排、本地库、outbox / 映射 / 游标保持共用，
GReader 行为不变。Inoreader / Feedly 需要 OAuth 客户端与官方授权，暂不提供。

## Requirements

- **FR-001**: `RemoteBackend` 定义认证、订阅列表、文章分页、未读 / 收藏 id、状态回写与游标比较。
- **FR-002**: GReader 后端行为与改造前一致（probe + ClientLogin、continuation、edit-tag 分组 / 逐条兜底）。
- **FR-003**: Feedbin 使用 `https://api.feedbin.com/v2/` + Basic Auth（email / password）。
- **FR-004**: Feedbin 订阅来自 `/subscriptions.json`，`feed_id` 作为拉文章的分组键。
- **FR-005**: Feedbin 文章按 `/feeds/{feed_id}/entries.json` 分页（`per_page=100`），
      增量用 `since=<created_at ISO>`；游标按 ISO 时间比较。
- **FR-006**: Feedbin 未读 / 收藏分别来自 `unread_entries.json` / `starred_entries.json`。
- **FR-007**: Feedbin 状态回写使用批量 POST 端点（含 `/delete.json` 变体），不走 DELETE，兼容代理。
- **FR-008**: 切换服务类型或地址时清理旧映射 / outbox / 游标，避免跨协议误判。
- **FR-009**: 账号页可选择服务类型；Feedbin 预填默认地址、隐藏明文 HTTP 开关并使用邮箱文案。
- **FR-010**: 凭据仍只存系统 Asset Store；不新增权限、不新增外发数据类别。

## Acceptance

- 账号页选择 Feedbin 后，用邮箱 + 密码可连接并拉取订阅 / 文章。
- 在 Feedbin 端标已读 / 收藏，下一次同步可拉回；本地标已读 / 收藏可回写。
- 重复同步不重复插入文章；增量游标使用 `created_at`，不会因文章发布时间回溯而漏拉。
- 已连接的 GReader 账号仍可正常同步；切换服务类型后不会沿用另一协议的游标 / 映射。
- 连接失败按网络 / 鉴权 / API / 限流 / 解析分类提示。
