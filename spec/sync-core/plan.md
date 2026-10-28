# Plan: 账号与云同步（同步内核第一批）

## 分层

```
model/Sync.ets                    记录 / 分页 / 摘要 / 字段合并（纯函数）
service/sync/SyncBackend.ets      传输抽象（pull / push / betterCursor / reset）
service/sync/MockSyncBackend.ets  本机「远端」实现（偏好库 + rev 游标）
service/sync/SyncStore.ets        sync_records 表读写（复用 articleStore.getStore()）
service/sync/SyncEngine.ets       拉取 → 合并 → 推送 → 游标（与数据源无关）
service/sync/SyncCollector.ets    订阅源 / 文章状态 ↔ SyncRecord 的差量采集与应用
service/SyncService.ets           单例编排：开关、状态、collect + engine + apply
views/SyncView.ets                设置页二级页（演示 + 手动同步）
```

## 数据流

1. `collect()`：读 `FeedStore` + `ArticleStore.loadForList()`，与 `sync_records` 比对，
   变化项写回并置 `dirty = 1`（时间戳取当前时间，未变化的字段保留原 `at`）。
2. `engine.sync()`：
   - `pull(cursor)` 分页拉取 → 与本地记录按 `mergeRecord` 合并；
   - 合并结果与远端不一致 → 标 `dirty = 1`（本地改动 + 合并结果一起待推送）；
   - 保存游标；
   - `push(dirty)` → 成功项 `dirty = 0`，失败项保留待重试。
   - **先拉后推**：后端按整条记录覆盖落库，先推会把对端改过的其它字段盖掉，
     先拉才能做字段级合并，再把完整状态一次回写。
3. `apply()`：把合并后的订阅源 / 文章状态写回现有存储，并刷新 ViewModel。

## 关键取舍

- **字段级状态合并**：文章状态载荷不是整条快照，而是每字段 `{ value, at }`，
  避免「B 端只标收藏」把「A 端的已读」回滚。
- **差量采集而非写入口埋点**：`ArticleStore` 的写入口很多（列表、详情、多选、规则、批量），
  逐个埋点容易漏；用快照比对能覆盖全部路径，代价是一次 O(n) 扫描（手动同步触发，可接受）。
- **墓碑删除**：删除不立即从同步表消失，否则无法把删除传播到另一端。
- **Mock 落在本机偏好库**：不联网、不新增权限，演示与验收都能在模拟器完成。

## 迁移

- `ArticleStore` 新增 `sync_records` 建表语句（`CREATE TABLE IF NOT EXISTS`，幂等），
  `SCHEMA_VERSION` 8 → 9；老库打开即自愈，无需数据回填。

## 验证

- 单测：字段级合并、LWW 与平局、墓碑、推送脏标记、游标推进、幂等、采集差量。
- 模拟器：设置 → 云同步 → 开启 → 立即同步 → 看状态与待推送归零；标一篇已读再同步；重置远端。
