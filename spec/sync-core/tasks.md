# Tasks: 账号与云同步（同步内核）

- [X] T001 `model/Sync.ets`：`SyncRecord` / `SyncPullPage` / `SyncPushResult` / `SyncSummary` / 字段级合并
- [X] T002 `service/sync/SyncBackend.ets`：传输抽象（pull / push / betterCursor / reset / name）
- [X] T003 `service/sync/MockSyncBackend.ets`：偏好库远端 + 自增 rev 游标 + 重置
- [X] T004 `sync_records` 建表与 `SCHEMA_VERSION` 8 → 9（幂等自愈）
- [X] T005 `service/sync/SyncStore.ets`：脏标记、游标、墓碑、批量读写
- [X] T006 `service/sync/SyncEngine.ets`：拉取 → 合并（标脏）→ 推送 → 游标
- [X] T007 `service/sync/SyncCollector.ets`：订阅源 / 文章状态差量采集与应用
- [X] T008 `service/SyncService.ets`：单例编排、开关与状态持久化
- [X] T009 `views/SyncView.ets` + 路由 + 设置页入口 + 中英与六语言文案
- [X] T011 单测：`SyncMerge.test.ets` / `SyncEngine.test.ets` / `SyncCollector.test.ets`
- [X] T012 `arkts_check` / 纯 V2 自查 / `build_project` / ohosTest（347 例全通过）
- [X] T013 README / TODO / PRIVACY 同步说明
