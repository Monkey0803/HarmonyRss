# Tasks: 账号与云同步（内容实体第三批）

- [X] T001 `model/Sync.ets`：`highlight` / `tag` / `articleTag` / `settings` 类型、稳定键与载荷编解码
- [X] T002 `SyncStore.isSyncableKind` 覆盖新类型
- [X] T003 `SyncCollector.collectSnapshots`：通用差量采集（payload 比对 + 可选墓碑）
- [X] T004 高亮采集 / 应用（文章不存在时跳过，墓碑删除）
- [X] T005 标签采集 / 应用（归一化名称为键，同名复用与改名）
- [X] T006 文章↔标签关联采集 / 应用（名称解析 + 文章存在性检查）
- [X] T007 设置采集 / 应用（备份白名单 + 仅在变化时写回与主题 / 语言副作用）
- [X] T008 单测：`SyncContent.test.ets`（往返 / 脏数据 / 键 / LWW 与墓碑）
- [X] T009 `arkts_check` / 纯 V2 自查 / `build_project` / ohosTest（367 例全通过）
- [X] T010 README / PRIVACY / TODO 同步说明
- [X] T011 智能文件夹同步（名称 + 检索语法，排序位不同步）
- [X] T012 规则同步（订阅源按 URL、标签按名称解析；优先级 / 命中统计不同步）
- [X] T013 分享模板同步（跳过内置默认模板）
- [X] T014 新载荷单测（文件夹 / 规则 / 模板往返与脏数据过滤）
