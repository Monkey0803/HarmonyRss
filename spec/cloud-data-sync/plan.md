# Plan: 端云数据同步（华为云空间）

## 改动点

```
AppScope/app.json5                     cloudStructuredDataSyncEnabled: true
module.json5                           DISTRIBUTED_DATASYNC（reason + usedScene）
service/sync/CloudStore.ets             独立库 / 建表 / 登记分布式表 / 网络策略 / 订阅 / 手动 cloudSync
service/sync/CloudRelayBackend.ets      SyncBackend 实现（游标 = updatedAt 毫秒字符串）
service/SyncService.ets                 同步目标切换、准备云库、云端变更 → autoSync、状态显示
views/SyncView.ets                      「端云数据同步（实验）」开关 + 云端说明
resources/*/element/string.json         3 个新 key + 权限 reason（7 语言）
ohosTest/CloudRelay.test.ets            游标解析 / 比较
```

## 数据流

1. 用户开启「端云数据同步」→ `setCloudBackend(true)` → 打开 `harmonyrss_cloud.db` → 登记分布式表 → 设置网络策略。
2. 同步一轮：`collect()` 标脏 → `cloudStore.syncNow()` 拉云端行 → `CloudRelayBackend` 作为远端：
   pull 增量 → 合并 → 推送本机改动与合并结果 → 游标。
3. 系统把表行同步到云端；另一台同账号设备收到 `dataChange` → 触发自动同步 → 合并回本地领域表。

## 关键取舍

- **独立库而不是复用 `harmonyrss.db`**：AGC 列只能加不能删，把业务表全量上云会把 schema 演进锁死；
  独立库只有 6 列，且与同步记录一一对应。
- **`updatedAt` 存 String**：控制台没有 Long，Integer 可能是 32 位，毫秒时间戳会溢出。
- **行级 LWW + 本地字段级合并**：云侧只按行覆盖，字段级合并仍在 `SyncRecord` 层完成。
- **游标用 updatedAt**：同步记录本身没有全局自增版本；云端晚到的旧行可能被跳过，
  用 `dataChange` 回调触发一次同账号合并来兜底。
