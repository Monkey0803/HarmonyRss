# Tasks: 端云数据同步（华为云空间）

- [X] T001 AGC 侧：容器 `harmonyrss_cloud` / 数据类型 `cloudSyncRecords`（用户已完成）
- [X] T002 `app.json5` 开启 `cloudStructuredDataSyncEnabled`；`module.json5` 声明 `DISTRIBUTED_DATASYNC`
- [X] T003 `CloudStore`：独立库 `harmonyrss_cloud.db` + 6 列表 + `setDistributedTables`（失败降级）
- [X] T004 `CloudStore`：网络策略（仅 Wi-Fi）、手动 `cloudSync`、云端变更订阅 / 退订
- [X] T005 `CloudRelayBackend`：`pull` / `push` / `betterCursor` / `reset`
- [X] T006 `SyncService`：同步目标切换、云库准备、云端变更 → 自动同步、状态后端名
- [X] T007 `SyncView`：「端云数据同步（实验）」开关 + 云端说明；七语言文案
- [X] T008 单测：`CloudRelay.test.ets`（游标解析 / 比较 / 脏值）
- [X] T009 `check-i18n` / `arkts_check` / `build_project` / ohosTest（372 例全通过）
- [X] T010 README / PRIVACY / 权限审计 / TODO 同步说明
- [ ] T011 跨设备实测（需第二台登录同一华为账号的设备）：一端标已读 / 收藏，另一端自动更新
      —— 单机已验证：分布式表登记成功、手动同步 33 条、待推送 0、无失败日志
