# Implementation Plan: 标签与智能文件夹

**Input**: `spec/tags-rules/spec.md`

## Summary

在现有本地库上新增三张表（`tags` / `article_tags` / `smart_folders`），schema v3 → v4；
新增标签选择器、标签页、标签文章页、智能文件夹页，并在订阅页与首页多选工具条接入。
智能文件夹**复用现有搜索链路**（`SearchQueryParser` + `SearchStore`），不新增查询 DSL；
标签筛选走 SQL JOIN，文章读取沿用轻量列（不带正文），避免内存膨胀。

## Technical Context

**Language/Version**: ArkTS / HarmonyOS SDK（工程 modelVersion 6.1.0）
**Primary Dependencies**: `@kit.ArkData`（relationalStore）、`@kit.ArkUI`、`@kit.UIDesignKit`（HDS）
**State Management**: 沿用 State Management V2
**Storage**: relationalStore（`harmony_rss.db`，schema v3 → v4）+ preferences（搜索历史沿用）
**Testing**: `entry/src/ohosTest`（hypium）+ `arkts_check` + `build_project`
**Target Platform**: HarmonyOS 手机 / 平板
**Project Type**: mobile-app（单 entry 模块）
**Performance Goals**: 2 万篇文章、50 个标签下标签筛选首屏 < 300ms；批量 100 篇打标 < 2s
**Constraints**: 纯本地；不改动现有检索语义；标签关联随文章删除/清理/恢复同步；迁移失败不删库
**Scale/Scope**: 标签 ≤100、智能文件夹 ≤50；新增 3 张表、2 个 ViewModel、4 个视图、1 个选择器

## Project Structure

### Documentation (this feature)

```text
spec/tags-rules/
├── spec.md
├── plan.md              # This file
└── tasks.md
```

### Source Code (repository root)

沿用现有 MVVM 分层，不新增顶层目录：

```text
entry/src/main/ets/
├── model/
│   ├── Tag.ets                       # 新增：TagWithCount / SmartFolder
│   └── Search.ets                    # 不改（智能文件夹复用 SearchQuery）
├── common/constants/
│   ├── RssConstants.ets              # 修改：SCHEMA_VERSION 3→4；标签/智能文件夹表名与上限
│   └── RouterConstants.ets           # 修改：PAGE_TAGS / PAGE_TAG_ARTICLES / PAGE_SMART_FOLDERS
├── service/
│   ├── ArticleStore.ets              # 修改：v4 建表；删除/清理/恢复/删源时级联标签关联；暴露共享 store
│   ├── TagStore.ets                  # 新增：标签 CRUD、打标/取消、按标签取文章、计数
│   └── SmartFolderStore.ets          # 新增：智能文件夹 CRUD 与排序
├── viewmodel/
│   ├── TagViewModel.ets              # 新增：标签列表/计数/选择态/批量打标/标签文章
│   ├── SmartFolderViewModel.ets      # 新增：智能文件夹列表与 CRUD
│   └── SearchViewModel.ets           # 修改：pendingQuery（供智能文件夹跳转）+ 保存当前查询回调
├── views/
│   ├── TagsView.ets                  # 新增：标签列表（多选 AND）+ 管理
│   ├── TagArticlesView.ets           # 新增：标签文章列表
│   ├── SmartFoldersView.ets          # 新增：智能文件夹列表与编辑入口
│   ├── TagPickerSheet.ets            # 新增：标签选择器（详情页 / 批量共用）
│   ├── SubscriptionsView.ets         # 修改：顶部「标签 / 智能文件夹」入口
│   ├── HomeTabView.ets               # 修改：多选工具条新增「标签」
│   ├── ArticleDetailView.ets         # 修改：展示/增删文章标签
│   └── SearchView.ets                # 修改：消费 pendingQuery；「保存为智能文件夹」
└── pages/Index.ets                   # 修改：注册 3 个 NavDestination

entry/src/main/resources/
├── base/element/string.json          # 新增英文文案（tag_* / smart_folder_*）
└── zh_CN/element/string.json         # 新增中文文案

entry/src/ohosTest/ets/test/
├── TagStore.test.ets                 # 新增：名称归一、去重、级联
└── SmartFolder.test.ets              # 新增：查询校验与排序
```

**Structure Decision**: 遵循现有工程架构（MVVM 已存在），不新建 `data/` 层。标签/智能文件夹 SQL 放在独立 Store，数据库结构仍由 `ArticleStore` 统一迁移；`ArticleStore` 暴露共享 `RdbStore` 访问器，避免同进程重复打开同名库。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
| --------- | ---------- | ------------------------------------ |
| 独立 TagStore / SmartFolderStore | `ArticleStore` 已 2000+ 行，继续堆会不可维护 | 全塞进 ArticleStore：职责混乱、测试困难 |
| 标签文章独立页面 | 复用现有列表组件与轻量列读取，避免改动首页筛选状态机 | 并入首页筛选：与未读/收藏/归档、分页、分组互相干扰 |

## Research & Decisions

### R-01 数据库结构归属与共享连接

- **Decision**: 三张表由 `ArticleStore.migrate()` 统一创建（v4）；`ArticleStore` 暴露 `getStore()` 供 `TagStore` / `SmartFolderStore` 复用同一 `RdbStore` 实例。
- **Rationale**: 官方明确同一进程不要重复打开同名数据库；结构迁移集中在一处更容易保证版本一致。
- **Alternatives considered**: 各 Store 自行 `getRdbStore`（可能触发同名库异常）；把标签 SQL 全塞进 ArticleStore（文件过大）。

### R-02 标签标识与唯一性

- **Decision**: `tags` 使用稳定 id（`tag_<时间戳>_<随机串>`），另存 `name_key`（trim + 折叠空白 + 转小写）做唯一约束；重命名只改 `name` / `name_key`，关联表不动。
- **Rationale**: 支持重命名而不产生悬挂关联；大小写不敏感去重符合用户直觉。
- **Alternatives considered**: 用名称当主键（重命名需级联更新子表）；仅靠应用层去重（并发/重启后可能重复）。

### R-03 标签与文章的关联生命周期

- **Decision**: 用户删除文章、删源、清理进回收站时**保留** `article_tags` 行；仅在「回收站过期清除」时删除。所有计数与筛选查询都 JOIN `articles`，因此孤儿关联不会被计入。
- **Rationale**: 让「清理 → 7 天内恢复」能连同标签一起恢复；避免恢复后标签丢失。
- **Alternatives considered**: 删除文章即删关联（恢复后标签丢失）；外键级联（RDB 默认不保证开启外键）。

### R-04 多标签筛选语义

- **Decision**: 多标签为 AND：`JOIN article_tags ... WHERE tag_id IN (...) GROUP BY article_id HAVING COUNT(DISTINCT tag_id) = N`。
- **Rationale**: 与「同时具备」的直觉一致，且能走 `article_tags(tag_id, article_id)` 复合索引。
- **Alternatives considered**: OR（结果太宽，无法表达主题交集）；层次标签（超出 v1 范围）。

### R-05 智能文件夹执行方式

- **Decision**: 智能文件夹只存原始查询串；点击时把查询写入 `SearchViewModel.pendingQuery`，跳转现有搜索页并自动提交。搜索页新增「保存为智能文件夹」，把当前 `raw` 存为新条目。
- **Rationale**: 100% 复用现有 FTS/中文索引/分页/高亮/命中定位，保证「结果与搜索一致」。
- **Alternatives considered**: 新写一套结果页（重复实现、易分叉）；把查询编译成结构化条件存库（语法演进后不兼容）。

### R-06 标签文章列表读取

- **Decision**: 新增 `TagStore.articlesByTags(tagIds, offset, limit)`，只取列表所需轻量列（不含正文/HTML），按 `published_at DESC` 分页；打开文章沿用 `FeedViewModel.openArticleById`（必要时按库补全正文）。
- **Rationale**: 与现有列表内存策略一致；避免标签页把正文读进内存。
- **Alternatives considered**: 在 `FeedViewModel.all` 上内存过滤（标签文章可能不在已加载范围，且多标签 AND 维护成本高）。

### R-07 入口与交互

- **Decision**:
  - 订阅页顶部新增两个入口行：`标签（N）`、`智能文件夹（N）`；
  - 首页多选工具条新增「标签」，打开 `TagPickerSheet` 批量打标；
  - 详情页在标题下展示标签 chips，`+` 打开同一选择器；
  - `TagsView` 支持多选（AND）后进入 `TagArticlesView`；长按/菜单进入重命名、删除。
- **Rationale**: 不动 HDS 页签结构，入口集中，复用同一选择器。
- **Alternatives considered**: 新增第四页签（改动导航与沉浸光感布局）；并入首页筛选条（状态互相干扰）。

### R-08 迁移与降级

- **Decision**: `SCHEMA_VERSION` = 4；`open()` 对已是最新版本的库也执行 `CREATE TABLE IF NOT EXISTS`（自愈）；迁移失败不回滚、不删库，标签功能降级为不可用（页面显示空态），阅读/检索不受影响。
- **Rationale**: 标签是增强能力，不能因结构问题影响主链路。
- **Alternatives considered**: 迁移失败即清库（丢失用户数据）。

## Data Model

### 数据库（`harmony_rss.db`，v3 → v4）

**`tags`**

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| id | TEXT | PRIMARY KEY | 稳定标识 |
| name | TEXT | NOT NULL | 展示名（trim 后，≤32） |
| name_key | TEXT | NOT NULL UNIQUE | 归一化名称（小写 + 空白折叠），用于去重 |
| created_at | INTEGER | NOT NULL | 毫秒时间戳 |

**`article_tags`**

| 列 | 类型 | 约束 |
| --- | --- | --- |
| article_id | TEXT | NOT NULL |
| tag_id | TEXT | NOT NULL |
| PRIMARY KEY | (article_id, tag_id) | 联合唯一 |

索引：`idx_article_tags_tag ON article_tags(tag_id, article_id)`。

**`smart_folders`**

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| id | TEXT | PRIMARY KEY | 稳定标识 |
| name | TEXT | NOT NULL | 名称（≤32） |
| query | TEXT | NOT NULL | 检索语法原始串（≤512） |
| sort_order | INTEGER | NOT NULL | 手动排序位 |
| created_at | INTEGER | NOT NULL | 毫秒 |
| updated_at | INTEGER | NOT NULL | 毫秒 |

索引：`idx_smart_folders_order ON smart_folders(sort_order)`。

### 领域模型（`model/Tag.ets`）

- `TagWithCount`：`id`、`name`、`count`、`createdAt`。
- `SmartFolder`：`id`、`name`、`query`、`sortOrder`、`createdAt`、`updatedAt`。
- 上限常量：`MAX_TAGS = 100`、`MAX_SMART_FOLDERS = 50`、`TAG_NAME_MAX = 32`、`SMART_FOLDER_QUERY_MAX = 512`。

## Contracts & Interfaces

### ArticleStore（扩展）

- `getStore(): relationalStore.RdbStore | undefined`：供标签/智能文件夹 Store 复用同一连接。
- `migrate()` v4：创建 `tags` / `article_tags` / `smart_folders` 与索引（可重复执行）。
- 级联：
  - `deleteMany(ids)`：删除对应 `article_tags`；
  - `deleteByFeed(feedId)`：删除该源文章的 `article_tags`；
  - `purgeTrash(beforeTs)`：删除被清除文章的 `article_tags`；
  - `archiveToTrash` / `restoreTrash`：**不**删除关联（保证恢复后标签仍在）。

### TagStore（新增）

- `listTags(): Promise<TagWithCount[]>`：LEFT JOIN 文章计数，按 `created_at` 升序（或名称）。
- `create(name): Promise<TagWithCount | undefined>`：归一 + 去重（已有则返回已有），超上限返回 undefined。
- `rename(id, name): Promise<boolean>`
- `remove(id): Promise<void>`
- `addToArticles(tagId, ids): Promise<number>`：`INSERT OR IGNORE`，批量事务。
- `removeFromArticle(tagId, articleId): Promise<void>`
- `tagsOfArticle(articleId): Promise<TagWithCount[]>`
- `articlesByTags(tagIds, offset, limit): Promise<Article[]>`：AND 语义，轻量列，按时间倒序。
- `countByTags(tagIds): Promise<number>`
- `countTags(): Promise<number>`

### SmartFolderStore（新增）

- `list(): Promise<SmartFolder[]>`
- `create(name, query): Promise<SmartFolder | undefined>`（校验：名称非空、`emptyQuery(query) === false`、数量未超限）
- `update(id, name, query): Promise<boolean>`
- `remove(id): Promise<void>`
- `move(id, delta): Promise<void>`：交换相邻 `sort_order`。

### 查询校验契约

- 复用 `SearchQueryParser.emptyQuery(raw)`：空串 / 纯空白 / 仅无效语法 → 拒绝保存。
- 查询串长度 ≤ 512；名称长度 ≤ 32。

### ViewModel 契约

- `TagViewModel`
  - 状态：`tags: TagWithCount[]`、`selectedTagIds: string[]`、`activeTags: TagWithCount[]`、`tagArticles: Article[]`、`loading`、`failed`
  - 方法：`load()`、`toggleSelect(id)`、`create(name)`、`rename(id, name)`、`remove(id)`、`openTagArticles(nav)`、`tagArticlesFor(tagIds)`、`tagsOf(articleId)`、`addTagsToArticles(ids, tagId)`
- `SmartFolderViewModel`
  - 状态：`folders: SmartFolder[]`、`loading`、`failed`、`editing`
  - 方法：`load()`、`create(name, query)`、`update(id, name, query)`、`remove(id)`、`move(id, delta)`、`open(folder)`（写 `searchViewModel.pendingQuery` 后跳转搜索页）
- `SearchViewModel`（扩展）
  - `pendingQuery: string`、`takePendingQuery(): string`、`currentRaw(): string`（供保存智能文件夹）

### 路由与页面契约

| 路由 | 页面 | 入口 |
| --- | --- | --- |
| `PAGE_TAGS` = `tags` | `TagsView` | 订阅页「标签」行 |
| `PAGE_TAG_ARTICLES` = `tagArticles` | `TagArticlesView` | 标签页选择后进入 |
| `PAGE_SMART_FOLDERS` = `smartFolders` | `SmartFoldersView` | 订阅页「智能文件夹」行 |

- `TagsView`：列表（名称 + 计数 + 选中态）、多选 AND、底部「查看结果」、行菜单（重命名 / 删除）。
- `TagArticlesView`：标签标题 + 文章列表（LazyForEach + 轻量列），点击打开详情。
- `SmartFoldersView`：列表（名称 + 查询串摘要）、新建/编辑（名称 + 查询输入）、删除、上移/下移。
- `TagPickerSheet`：已有标签复选 + 新建输入；确认后回调选中 id 列表。
- `SearchView`：进入时若有 `pendingQuery` 自动填入并提交；结果区提供「保存为智能文件夹」。
- `HomeTabView`：多选工具条新增「标签」，打开 `TagPickerSheet`。
- `ArticleDetailView`：标题下方展示标签 chips，`+` 打开 `TagPickerSheet`。

### 资源契约

- 文案 key 前缀：`tag_*`、`smart_folder_*`；中英成对。
- 复用现有颜色/尺寸；标签 chip 复用 `radius_chip` / `value_chip_height` 等既有 float。
