# Plan: 云空间备份（端云文件协同）

## 改动点

```
service/BackupFiles.ets           云目录探测 / 写入 / 读取 / 元信息（含可选文件名，供单测隔离）
service/BackupService.ets         backupToCloud / restoreFromCloud / cloudInfo（复用串行锁）
viewmodel/BackupViewModel.ets     cloudAvailable / cloudExists / cloudAt + 两个动作
views/BackupView.ets              「云空间备份」分区：说明、上次时间、备份 / 恢复按钮
resources/*/element/string.json   7 语言文案（9 个 key）
ohosTest/CloudBackup.test.ets     云目录真实读写（设备不支持时静默跳过）
```

## 数据流

1. 备份：`collect()` → `serialize()` → 写 `cloudFileDir/harmonyrss-cloud-backup.json`（覆盖）。
2. 系统：写入完成后端云协同自动上传并下发到同账号设备（应用不参与）。
3. 恢复：读文件 → `parse()` → `applyDocument(restoreSettings)` → 刷新列表与计数。

## 关键取舍

- **固定文件名**：云空间只保留最新状态，避免多端各写一份互相覆盖的历史文件；
  需要历史时继续用本机 7 份快照。
- **可用性看目录是否存在**：真机上未开通云空间时 `cloudFileDir` 路径存在但目录不可写
  （mkdir 报 Permission denied），所以不用「路径非空」判断可用，避免按钮可点却必然失败。
- **不加云侧配置**：不启用 `cloudStructuredDataSyncEnabled`，用户不会在「设置 > 云空间」
  看到额外开关，隐私页也无需新增外发条目（数据只在用户自己的云空间里）。
