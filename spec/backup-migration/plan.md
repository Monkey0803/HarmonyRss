# Implementation Plan: 备份与迁移

**Input**: `spec/backup-migration/spec.md`

## Summary

新增版本化 JSON 备份：导出时聚合订阅、文章元数据与状态、高亮、标签、智能文件夹、规则、分享模板与设置；
导入时按各自主键/归一化键**合并**（状态取并集，不删除现有数据），并保持幂等。
同时每日在应用私有目录生成快照并保留 7 份。备份不含正文 HTML、远端凭据与设备路径。

## Technical Context

**Language/Version**: ArkTS / HarmonyOS SDK（工程 modelVersion 6.1.0）
**Primary Dependencies**: `@kit.CoreFileKit`（picker / fileIo）、`@kit.ArkData`（relationalStore / preferences）、`@kit.ArkUI`
**State Management**: 沿用 State Management V2
**Storage**: RDB（读取/合并）+ preferences（设置、模板）+ 应用私有目录（快照）
**Testing**: `entry/src/ohosTest`（hypium，纯 codec 逻辑）+ `arkts_check` + `build_project`
**Target Platform**: HarmonyOS 手机 / 平板
**Project Type**: mobile-app（单 entry 模块）
**Performance Goals**: 2 万篇导出 < 10s / < 20MB；导入 < 30s；不阻塞 UI
**Constraints**: 合并不删除；幂等；不含正文与凭据；失败不改数据
**Scale/Scope**: 单文件备份；快照 7 份；新增 1 个 codec、1 个 service、1 个 VM、1 个页面

## Project Structure

### Documentation (this feature)

```text
spec/backup-migration/
├── spec.md
├── plan.md              # This file
└── tasks.md
```

### Source Code (repository root)

```text
entry/src/main/ets/
├── model/
│   └── Backup.ets                    # 新增：BackupDocument 与各段 DTO / BackupSummary / SnapshotInfo
├── common/constants/
│   ├── RssConstants.ets              # 修改：BACKUP_VERSION、快照目录/保留份数
│   ├── RouterConstants.ets           # 修改：PAGE_BACKUP
│   └── PreferencesConstants.ets      # 修改：KEY_LAST_SNAPSHOT_AT
├── service/
│   ├── BackupCodec.ets               # 新增：序列化/解析/校验/合并决策（纯逻辑）
│   ├── BackupService.ets             # 新增：聚合导出、合并导入、文件选择、快照管理
│   ├── BackupFiles.ets               # 新增：私有目录快照读写与清理
│   ├── ArticleStore.ets              # 修改：备份用批量读取 / 合并写入 / 状态并集
│   ├── TagStore.ets                  # 修改：全量标签与关联的读取/导入
│   ├── SmartFolderStore.ets          # 修改：按 id 导入
│   ├── RuleStore.ets                 # 修改：按 id 导入
│   ├── FeedStore.ets                 # 复用：encode/decode 与全量保存
│   └── SettingsStore.ets             # 复用：设置读取/保存
├── viewmodel/
│   ├── BackupViewModel.ets           # 新增：导出/导入/快照状态与编排
│   └── FeedViewModel.ets             # 修改：导入后重载订阅与文章
├── views/
│   ├── BackupView.ets                # 新增：备份与恢复页（导出/导入/恢复设置开关/快照列表）
│   └── SettingsTabView.ets           # 修改：「备份与恢复」入口
└── pages/Index.ets                   # 修改：注册 PAGE_BACKUP；启动触发自动快照

entry/src/main/resources/
├── base/element/string.json          # 新增 backup_* 文案（英文）
└── zh_CN/element/string.json         # 新增 backup_* 文案（中文）

entry/src/ohosTest/ets/test/
├── BackupCodec.test.ets              # 新增：版本校验、合并决策、幂等键
└── BackupMerge.test.ets              # 新增：状态并集、跳过规则、设置白名单
```

**Structure Decision**: 沿用现有架构。序列化与合并决策放纯函数 `BackupCodec`（可单测），文件与数据库操作放 `BackupService` / `BackupFiles`，UI 只消费 `BackupViewModel`。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
| --------- | ---------- | ------------------------------------ |
| 独立 codec 与 service | 版本兼容、字段校验、合并决策都需要单测 | 全塞进页面：不可测、易回归 |
| 备份用批量 SQL | 2 万篇逐条调用现有方法过慢 | 复用单条 API：导出/导入会超时 |

## Research & Decisions

### R-01 备份格式与版本

- **Decision**: 单一 JSON 文件：`{ version: 1, exportedAt, app, feeds[], articles[], highlights[], tags[], articleTags[], smartFolders[], rules[], templates[], settings{} }`。未知字段忽略，版本不匹配直接拒绝。
- **Rationale**: 结构简单、可读、可增量扩展；版本号保证向后兼容。
- **Alternatives considered**: ZIP（需要额外打包与解包）；数据库文件直拷（跨版本不安全）。

### R-02 内容范围

- **Decision**: 导出文章仅含元数据与状态列（id/feedId/feedTitle/title/link/summary/author/publishedAt/imageUrl/read/starred/saved/progress/progressRatio/hidden/canonicalId/linkKey/titleKey），不含 `content/content_html/reader_html/plain_text/page_etag`。
- **Rationale**: 满足换机恢复阅读状态，体积可控；正文可重新提取。
- **Alternatives considered**: 含正文（体积数倍，导入慢）；仅状态（无标题/链接无法展示）。

### R-03 合并键与状态并集

- **Decision**: feeds 按归一化 URL；articles 按 id；highlights 按 id；tags 按 `name_key`；articleTags 按 `(article_id, tag_id)`；smartFolders/rules 按 id；templates 按 id。状态合并：`read/starred/saved/hidden = 旧||新`，`progress = max(旧,新)`，`canonicalId` 保留旧值（空则取新）。
- **Rationale**: 不丢状态、不产生重复、幂等。
- **Alternatives considered**: 覆盖（丢现有数据）；逐项询问（交互过重）。

### R-04 缺失依赖的跳过

- **Decision**: 文章所属 feed 不在合并后的订阅集合中 → 跳过并计入 skipped；高亮所属文章不存在 → 跳过。导入不因单条失败中断。
- **Rationale**: 满足「跳过并统计」且保证其它数据可用。
- **Alternatives considered**: 自动创建占位订阅（会污染订阅列表）。

### R-05 设置导入

- **Decision**: 设置段仅包含白名单字段（主题/语言/材质/排版/列表/归档/去重/自动刷新/通知等），默认不应用；用户勾选「同时恢复设置」后才写入并应用主题/语言副作用。
- **Rationale**: 避免导入他人备份时覆盖本机偏好。
- **Alternatives considered**: 总是应用（破坏当前体验）。

### R-06 文件读写

- **Decision**: 复用 `OpmlService` 的 DocumentViewPicker 模式：导出保存 JSON（后缀 `.json`），导入选择单个 JSON 读取；文件 IO 统一 catch 返回失败。
- **Rationale**: 无需存储权限，用户可控位置。
- **Alternatives considered**: 固定目录导出（用户找不到文件）。

### R-07 自动快照

- **Decision**: 快照存 `context.filesDir/backups/backup-YYYYMMDD.json`；启动时若当日快照不存在则后台生成；保留最近 7 份（按文件名日期排序清理）。设置页显示时间/大小，可恢复/删除/立即备份。
- **Rationale**: 私有目录无需权限；按日期命名天然去重与排序。
- **Alternatives considered**: 每小时快照（过多）；存公共目录（权限与隐私）。

### R-08 导入性能与事务

- **Decision**: 按段批量写入：文章每 200 条一个事务；高亮/标签关联/规则同样分批；整体串行执行并在 UI 显示进度。「合并」使用 `INSERT OR IGNORE` + 冲突时 `UPDATE` 状态并集。
- **Rationale**: 2 万篇可在 30s 内完成；中途失败保留已导入部分，重跑幂等续传。
- **Alternatives considered**: 单事务全量（内存与锁压力大）。

### R-09 安全与隐私

- **Decision**: 备份不含远端密码/Token、剪贴板内容、自定义背景图路径；导出前在 UI 提示「文件包含你的阅读记录，请妥善保管」。
- **Rationale**: 满足 FR-003 与隐私预期。
- **Alternatives considered**: 加密备份（需要密码管理，后续再做）。

### R-10 依赖与回滚

- **Decision**: 不引入第三方库；导入失败只影响本次，不删除现有数据；快照与手动导入串行执行（同一把内存锁）。
- **Rationale**: 降低依赖与并发风险。
- **Alternatives considered**: 引入 zip/加密库（当前不必要）。

## Data Model

### 备份文档（`model/Backup.ets`）

- `BackupDocument`：version / exportedAt / feeds / articles / highlights / tags / articleTags / smartFolders / rules / templates / settings。
- `BackupFeed`：url / title / siteUrl / group / enabled / fetchIntervalMinutes / fullTextMode / retentionDays / notify / markReadOnScroll。
- `BackupArticle`：id / feedId / feedTitle / title / link / summary / author / publishedAt / imageUrl / read / starred / saved / progress / progressRatio / hidden / canonicalId / linkKey / titleKey。
- `BackupHighlight`：id / articleId / quote / note / color / createdAt / anchorText / anchorRatio。
- `BackupTag`：id / name / createdAt；`BackupArticleTag`：articleId / tagId。
- `BackupSmartFolder`：id / name / query / sortOrder；`BackupRule`：规则全字段（含统计可选）。
- `BackupTemplate`：id / name / content / sort。
- `BackupSettings`：白名单键值（字符串/布尔/数字）。
- `BackupSummary`：feedsAdded / articlesAdded / articlesUpdated / highlightsAdded / tagsAdded / skipped / failed。
- `SnapshotInfo`：fileName / path / sizeBytes / createdAt。

### 数据库与偏好

- 无 schema 变更；备份直接读写现有表与偏好。
- `KEY_LAST_SNAPSHOT_AT` 记录最近快照日期（避免重复生成）。

## Contracts & Interfaces

### BackupCodec（纯函数）

- `serialize(doc: BackupDocument): string`
- `parse(text: string): BackupDocument | undefined`（JSON 解析 + 版本校验 + 字段类型收敛）
- `mergeArticleState(existing, incoming): ArticleStatePatch`（并集决策）
- `statePatchSql(patch): string`（仅描述，实现产生 SQL）
- `settingsWhitelist(): string[]`
- `sanitizeFeed(feed): BackupFeed` / `sanitizeArticle(article): BackupArticle`（剔除敏感/无关字段）

### BackupService（新增）

- `exportToFile(context): Promise<boolean>`：聚合 → 序列化 → picker 保存。
- `importFromFile(context, restoreSettings: boolean): Promise<BackupSummary | undefined>`：picker 读取 → parse → 合并 → 返回统计。
- `snapshotNow(context): Promise<SnapshotInfo | undefined>`
- `maybeAutoSnapshot(context): void`（启动调用，当日已有则跳过）
- `listSnapshots(context): Promise<SnapshotInfo[]>`
- `restoreSnapshot(context, info): Promise<BackupSummary | undefined>`
- `deleteSnapshot(context, info): Promise<boolean>`
- `pruneSnapshots(context, keep: number): Promise<void>`

### 存储层扩展

- `ArticleStore`：
  - `allArticlesForBackup(): Promise<BackupArticle[]>`（批量 SQL，仅元数据列）
  - `mergeArticlesForBackup(records): Promise<{added, updated, skipped}>`（分批事务 + 状态并集）
  - `allHighlightsForBackup()` / `mergeHighlightsForBackup()`
  - `allArticleTagsForBackup()` / `mergeArticleTagsForBackup()`
- `TagStore`：`allForBackup()` / `mergeForBackup(records)`（按 name_key）
- `SmartFolderStore`：`allForBackup()` / `mergeForBackup(records)`（按 id）
- `RuleStore`：`allForBackup()` / `mergeForBackup(records)`（按 id）
- `FeedStore`：`mergeForBackup(feeds)`（按归一化 URL，保留本地独有）
- `SettingsStore`：`exportWhitelisted()` / `applyWhitelisted(settings)`（白名单）

### ViewModel 与页面

- `BackupViewModel`：exporting / importing / restoring / snapshots / summary / lastError；`exportNow(ability)`、`importNow(ability, restoreSettings)`、`snapshotNow`、`restore`、`delete`、`refreshSnapshots`。
- `BackupView`：导出按钮、导入按钮 + 「同时恢复设置」开关、快照列表（时间/大小/恢复/删除）、最近一次结果统计、隐私提示。
- `SettingsTabView`：「备份与恢复」入口。
- `Index`：注册 `PAGE_BACKUP`；`onPageShow` 调 `maybeAutoSnapshot`。

### 资源契约

- 文案 key 前缀 `backup_*`；中英成对；复用现有 row / button / dialog 样式。
