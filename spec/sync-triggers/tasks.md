# Tasks: 账号与云同步（自动触发第二批）

- [X] T001 `service/sync/AutoSyncPolicy.ets`：最小间隔 / 重试次数 / 指数退避（纯函数）
- [X] T002 `service/NetworkStatus.ets`：`isUnmetered()`（Wi-Fi / 以太网，异常按计费）
- [X] T003 `SyncService`：`autoSync`（开关 / 仅 Wi-Fi / 节流）与失败退避重试
- [X] T004 `SyncService`：仅 Wi-Fi 读写与 `SyncStatus.wifiOnly`
- [X] T005 `SyncView`：新增「仅 Wi-Fi 同步」开关 + 七语言文案
- [X] T006 `Index.onPageShow`：冷启动 / 回前台触发，成功后重读列表
- [X] T007 `FeedViewModel.commitFresh`：抓取完成触发
- [X] T008 单测：`AutoSyncPolicy.test.ets`（节流 / 绕过 / 退避 / 次数上限）
- [X] T009 `arkts_check` / 纯 V2 自查 / `build_project` / ohosTest（352 例全通过）
- [X] T010 README / TODO 同步说明
