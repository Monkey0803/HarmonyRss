# Tasks: 云空间备份（端云文件协同）

- [X] T001 `BackupFiles`：云目录探测（存在 / 元信息）+ 写入（自动建目录）+ 读取，失败一律返回空值
- [X] T002 `BackupService`：`backupToCloud` / `restoreFromCloud`，复用串行锁与 `applyDocument`
- [X] T003 `BackupViewModel`：`cloudAvailable` / `cloudExists` / `cloudAt` 与两个动作
- [X] T004 `BackupView`：「云空间备份」分区（不可用时只显示说明）
- [X] T005 七语言文案（说明 / 状态 / 两个动作 / 隐私 / 成功提示 / 不可用原因）
- [X] T006 单测：`CloudBackup.test.ets`（真实云目录读写，设备不支持时跳过；缺失文件返回空串）
- [X] T007 `check-i18n` / `build_project` / ohosTest（369 例全通过）
- [X] T008 README / PRIVACY / TODO 同步说明
- [X] T009 每日自动快照后顺带写云空间（默认开、可关闭、24h 节流、不可用时跳过）
