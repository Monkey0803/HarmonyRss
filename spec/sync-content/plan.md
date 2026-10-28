# Plan: 账号与云同步（内容实体第三批）

## 改动点

```
model/Sync.ets                   新增 HIGHLIGHT / TAG / ARTICLE_TAG / SETTINGS 类型、键与载荷编解码
service/sync/SyncStore.ets       isSyncableKind 覆盖新类型
service/sync/SyncCollector.ets   collectSnapshots 通用差量采集 + 四类 apply
ohosTest/SyncContent.test.ets    载荷往返 / 脏数据拒绝 / 键构造 / LWW 与墓碑
```

## 数据流

1. `collect`：
   - 高亮：`articleStore.allHighlightsForBackup()` → `highlight:<id>`；
   - 标签：`tagStore.allForBackup()` → `tag:<nameKey>`；
   - 关联：`allArticleTagsForBackup()` + 本地 tag 名称映射 → `articleTag:<nameKey>|<articleId>`；
   - 设置：`settingsStore.exportWhitelisted()` → 单条 `setting:app`。
   - 智能文件夹：`smartFolderStore.list()` → `smartFolder:<nameKey>`；
   - 规则：订阅源引用经 `feedMergeKey` 换成 URL、标签引用换成归一化名称后 → `rule:<nameKey>`；
   - 分享模板：`shareTemplates.list()`（跳过内置默认模板）→ `template:<nameKey>`。
   全部交给 `collectSnapshots(kind, current, now, tombstones)`：payload 相同就不动时间戳；
   本地消失的项按 kind 决定是否留墓碑（设置不留）。
2. `apply`（顺序：订阅源 → 文章状态 → 高亮 → 标签 → 关联 → 设置）：
   - 高亮：文章存在且载荷不同 → `addHighlight`（REPLACE）；墓碑 → `deleteHighlight`；
   - 标签：同名复用、展示名不同则 `rename`；墓碑 → `remove(id)`；
   - 关联：按名称解析 tag id，文章存在 → `addToArticles`；墓碑 → `removeFromArticle`；
   - 设置：白名单键逐个比较，有变化才 `applyWhitelisted` + 主题 / 语言副作用；
   - 智能文件夹 / 模板：同名复用，内容不同则 `update`；墓碑 `remove`；
   - 规则：引用反查本地 feed id / tag id（找不到的丢弃），内容一致不重写；墓碑 `remove`。

3. 新增 kinds 的键一律用名称：改名 = 删旧键 + 建新键，由差量采集自然产生墓碑。

## 关键取舍

- **标签用名称做键而不是 id**：id 由本机生成，跨设备必然不同；用名称才能让两端同名标签收敛。
  改名因此等价于「删旧键 + 建新键」，由差量采集自然产生墓碑。
- **副本里带上关联的标签名**：关联记录不依赖标签记录先到，应用时会补齐缺失标签。
- **设置不做墓碑**：缺键可能只是旧版本不知道这个设置，墓碑会误删。
- **复用备份白名单**：设置同步与备份恢复用同一份键清单，避免两处漂移。
