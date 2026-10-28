# Plan: 账号与云同步（自动触发第二批）

## 改动点

```
service/sync/AutoSyncPolicy.ets   节流 / 退避策略（纯函数）
service/NetworkStatus.ets         新增 isUnmetered()（Wi-Fi / 以太网判定）
service/SyncService.ets           autoSync / scheduleRetry / 仅 Wi-Fi 读写、状态快照扩展
views/SyncView.ets                新增「仅 Wi-Fi 同步」开关
pages/Index.ets                   onPageShow → autoSync('foreground')，成功后 reloadAfterBackup
viewmodel/FeedViewModel.ets       commitFresh 收尾 → autoSync('fetch')
ohosTest/AutoSyncPolicy.test.ets  策略单测
```

## 流程

1. 触发：`autoSync(context, trigger, throttle = true)`
   - 开关关闭 / 正在同步 → 返回 false；
   - 仅 Wi-Fi 且 `NetworkStatus.isUnmetered()` 为 false → 返回 false；
   - `Math.max(上次尝试, 上次成功同步)` 与当前时间做 `AutoSyncPolicy.isDue` 判断；
   - 通过后走 `syncNow()`。
2. 成功：清重试计数与定时器，返回 true；调用方按需刷新列表。
3. 失败：`scheduleRetry()` 按 `retryDelay(attempt)` 定时补试，`throttle = false` 绕过间隔。

## 关键取舍

- **节流用「上次成功同步或上次尝试」的时间**：失败不算成功，但也要阻止同一时段反复触发，
  所以取两者较大值；进程重启后 `lastAttemptAt` 归零，允许立刻同步一次。
- **仅 Wi-Fi 不约束手动同步**：用户主动点「立即同步」时不该被静默拒绝，
  真正的流量提示留给真实后端批次。
- **查询失败按计费处理**：宁可少同步一次，也不在用户不知情时走蜂窝流量。
