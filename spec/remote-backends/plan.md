# Implementation Plan: 远端服务适配层 + Feedbin

## Source Changes

- 新增 `service/remote/RemoteBackend.ets`：`RemoteBackend` 接口、`RemoteSession`、`RemoteArticlePage`、
  `RemoteStateChange`、`RemotePushResult`。
- 新增 `service/remote/GReaderBackend.ets`：复用 `GReaderClient`，把 continuation / 时间戳游标 /
  edit-tag 分批与逐条兜底搬进适配器。
- 新增 `service/remote/FeedbinModels.ets`：订阅 / 条目 / id 数组解析、Base URL 归一、ISO 游标比较。
- 新增 `service/remote/FeedbinBackend.ets`：Basic Auth、订阅、条目分页、未读 / 收藏、批量回写。
- 修改 `service/remote/RemoteSyncService.ets`：
  - 按 `account.serviceType` 选择后端；
  - `pullArticles` 改用 `RemoteArticlePage` + 不透明游标；
  - `pushStates` 改用中立的 `RemoteStateChange`，由后端负责协议细节；
  - `pullStates` 通过后端取未读 / 收藏 id。
- 修改 `RemoteAccountViewModel` / `RemoteServiceView`：服务类型选择、Feedbin 默认地址、文案与状态卡。
- 修改 `RemoteSyncConstants`：新增 `feedbin` 与默认 API 地址。
- 修改中英文案、README / TODO / PRIVACY。
- 测试：`FeedbinModels.test.ets` + `List.test.ets`。

## Decisions

- **接口按语义而非 HTTP 端点抽象**：Service 只关心「订阅 / 一页文章 / 未读集合 / 变更回写」，
  GReader 与 Feedbin 的协议细节各自封装，避免在编排层堆 serviceType 分支。
- **游标不透明**：GReader 用毫秒时间戳，Feedbin 用 `created_at` ISO；比较交给 Backend.betterCursor，
  避免在服务层混用数字 / 字符串语义。
- **状态回写保持幂等**：Feedbin 重复标记已读 / 收藏无副作用，统一网络层允许重试一次；
  部分失败按请求批次记入 outbox 失败计数，下次同步重试。
- **Feedbin 不走 DELETE**：使用官方提供的 POST `/delete.json` 变体，避免代理 / 客户端限制。
- **切换服务即清同步状态**：不同协议的 remote id / cursor 不通用，宁可重新全量首屏也不能误判。
