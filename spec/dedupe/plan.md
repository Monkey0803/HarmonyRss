# Implementation Plan: 跨源去重

**Input**: `spec/dedupe/spec.md`

## Summary

在文章入库时判定跨源重复：为新文章计算 URL/标题归一化键，命中已有文章则记录 `canonical_id` 挂靠到主条。
重复项仍保留在库中（保住来源与远端映射），但从列表/计数/检索/标签结果中排除；
组内已读/收藏/标签/隐藏同步，主条被删除或清理时提升组内最早入库的剩余文章。
升级时后台补齐旧文章的归一化键，使其也能作为合并候选。

## Technical Context

**Language/Version**: ArkTS / HarmonyOS SDK（工程 modelVersion 6.1.0）
**Primary Dependencies**: `@kit.ArkData`（relationalStore）、`@kit.ArkUI`
**State Management**: 沿用 State Management V2
**Storage**: relationalStore（schema v6 → v7：3 个新列 + 3 个索引）
**Testing**: `entry/src/ohosTest`（hypium）+ `arkts_check` + `build_project`
**Target Platform**: HarmonyOS 手机 / 平板
**Project Type**: mobile-app（单 entry 模块）
**Performance Goals**: 2 万篇下单篇入库去重判定额外 < 50ms；批量抓取 200 篇不显著变慢
**Constraints**: 仅跨源；入库时固化；不修改文章内容；失败降级为独立文章
**Scale/Scope**: 单组最多 5 个来源（超出仍挂靠但不展示）；新增 3 列、1 个服务、2 处 UI

## Project Structure

### Documentation (this feature)

```text
spec/dedupe/
├── spec.md
├── plan.md              # This file
└── tasks.md
```

### Source Code (repository root)

```text
entry/src/main/ets/
├── common/constants/
│   ├── RssConstants.ets              # 修改：SCHEMA_VERSION 6→7；表列常量、去重窗口 24h、来源上限
│   └── PreferencesConstants.ets      # 修改：KEY_DEDUPE_ENABLED
├── model/
│   ├── Feed.ets                      # 修改：Article 增加 canonicalId / duplicateCount / linkKey / titleKey
│   └── Dedupe.ets                    # 新增：DedupeCandidate / DedupeMatch / GroupSource
├── service/
│   ├── DedupeKeys.ets                # 新增：URL/标题归一化纯函数（可单测）
│   ├── DedupeService.ets             # 新增：候选查找、组 ID 展开、状态/标签同步、主条提升
│   └── ArticleStore.ets              # 修改：v7 迁移；插入时去重与键写入；列表/搜索排除重复项；状态组更新；删除/清理提升
├── viewmodel/
│   ├── FeedViewModel.ets             # 修改：状态操作走组同步；计数排除重复项；详情来源加载
│   └── SettingsViewModel.ets         # 修改：去重开关 setter
├── views/
│   ├── ArticleListItem.ets           # 修改：多来源标识
│   ├── ArticleDetailView.ets         # 修改：来源区（源名 + 链接）
│   └── SettingsTabView.ets           # 修改：去重开关行
├── pages/Index.ets                   # 不改路由
└── service/remote/RemoteSyncService.ets  # 修改：组展开入队；远端状态回写作用到组

entry/src/main/resources/
├── base/element/string.json          # 新增 dedupe_* 文案（英文）
└── zh_CN/element/string.json         # 新增 dedupe_* 文案（中文）

entry/src/ohosTest/ets/test/
├── DedupeKeys.test.ets               # 新增：URL/标题归一化
└── DedupePlan.test.ets               # 新增：候选匹配、组展开、主条提升决策（纯函数）
```

**Structure Decision**: 归一化与匹配决策放纯函数 `DedupeKeys` / `DedupeService` 的静态方法，SQL 与事务留在 `ArticleStore`；状态组同步由 `DedupeService` 统一入口，避免每个调用点各写一遍。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
| --------- | ---------- | ------------------------------------ |
| 新增 3 列 + 组状态同步 | 重复项必须保留来源与远端映射，同时状态一致 | 直接删除重复项：丢失来源、远端映射与后续提升能力 |
| 升级补键 | 旧文章不补键就无法与新文章合并 | 只对新文章生效：老订阅的重复无法消除 |

## Research & Decisions

### R-01 URL 归一化

- **Decision**: 小写 scheme/host；去掉 fragment；去掉 `utm_*`、`fbclid`、`gclid`、`ref`、`source` 等跟踪参数；去掉末尾 `/`；保留 path 大小写与查询参数顺序。
- **Rationale**: 覆盖绝大多数转载/聚合场景，同时避免误合并不同 query 的页面。
- **Alternatives considered**: 只去 fragment（跟踪参数导致漏合并）；全量排序 query（实现复杂且收益有限）。

### R-02 标题归一化与时间窗

- **Decision**: 标题转小写、去除空白与中英文标点后比较；发布时间相差 ≤24 小时；发布时间为 0 时用入库时间。
- **Rationale**: 转载标题常有标点/空格差异；24h 能覆盖跨时区发布。
- **Alternatives considered**: 编辑距离相似度（成本高、误合并风险）；无时间窗（旧文重复命中）。

### R-03 主条选择与稳定性

- **Decision**: 先入库者为永久主条；后续重复项 `canonical_id` 指向当前根主条（若命中的是重复项，则解析到其根）。只有主条被删除/清理时才提升。
- **Rationale**: 稳定、可预测，避免列表顺序跳变。
- **Alternatives considered**: 最新发布为主（每次新文章到达可能切换）；正文完整者（需要抓正文，入库时拿不到）。

### R-04 入库时匹配实现

- **Decision**: `ArticleStore.insertNew` / `insertRemote` 在插入前按批收集 linkKey 与 titleKey：
  - 一次查询 `WHERE link_key IN (...)`；
  - 一次查询 `WHERE title_key IN (...) AND published_at BETWEEN ? AND ?`；
  在内存中匹配（排除同 feed），确定 `canonical_id` 后再统一插入。
- **Rationale**: 避免每篇一次查询；200 篇一批只有 2 次额外查询。
- **Alternatives considered**: 逐篇查询（200 次查询，明显变慢）；全表扫描（不可接受）。

### R-05 重复项的索引策略

- **Decision**: 重复项**不写**主 FTS / 中文索引（列表与搜索均排除）；被提升为主条时再补齐索引。
- **Rationale**: 减少索引体积与写入放大；重复项本来不可见。
- **Alternatives considered**: 正常建索引（浪费空间，且搜索需额外过滤）。

### R-06 状态与标签组同步

- **Decision**: 新增 `DedupeService.groupIds(id)` 与组操作入口：
  - `applyRead/applyStarred/applyHidden(ids, value)` 展开为组内全部 id；
  - `applyTag(tagId, ids)` 对组内全部 id 打标；
  - 远端入队使用 `enqueueGroupState`（组展开后逐个入队）；
  - 远端状态回写先解析到主条，再作用整组。
- **Rationale**: 保证 UI、规则、远端三条路径行为一致。
- **Alternatives considered**: 只更新主条（副源状态不一致，远端回写遗漏）。

### R-07 主条删除/清理与提升

- **Decision**:
  - `deleteMany(ids)`：若删除包含主条，先在**不在删除列表**的重复项中选最早入库者提升（`canonical_id=''` + 补索引），其余重复项改指向新主条；无剩余则一并删除组内成员。
  - `archiveToTrash(ids)`：同样先提升；若组内全部在清理列表，则整组进回收站。
  - `restoreTrash`：恢复后若 `canonical_id` 指向不存在的主条，则清空并成为主条。
- **Rationale**: 满足「不丢文章」，同时避免悬挂引用。
- **Alternatives considered**: 主条删除即删全组（丢历史与来源）；保留悬挂引用（列表出现孤儿重复项）。

### R-08 升级补键

- **Decision**: v6→v7 加列建索引后，启动时后台分批（500/批）为 `link_key=''` 的文章补 URL/标题键，直到补完；失败保留已补部分，下次继续。
- **Rationale**: 让旧文章参与后续合并，且不阻塞启动。
- **Alternatives considered**: 迁移时同步全量计算（启动变慢）；不补键（旧重复无法消除）。

### R-09 规则与去重的协同

- **Decision**: 规则匹配仍针对新文章（含重复项）；执行动作前将计划中的 id 展开为组 id，保证标签/已读/收藏/隐藏作用到整组；同一组只累计一次命中统计（按主条计）。
- **Rationale**: 避免同一内容被多条规则重复计数，同时保持状态一致。
- **Alternatives considered**: 只对主条执行（重复项若先入库则规则丢失）。

### R-10 开关与降级

- **Decision**: `dedupeEnabled` 默认 true；关闭后新文章不合并（键照常写入，便于重新开启后并入已有主条）；去重查询/写入异常时降级为独立文章并记日志。
- **Rationale**: 满足总开关与「失败不影响入库」。
- **Alternatives considered**: 关闭后不写键（重新开启后无法并入）。

### R-11 风险与回滚

- **误合并**: 同标题不同文（如「周报」）在 24h 内可能误判；通过「主条 + 来源可展开」降低影响，后续可提供拆分入口。
- **性能**: 批量查询使用 IN 列表，需限制单批大小（200）避免 SQL 过长。
- **回滚**: `canonical_id` 清空即可拆分；新增列不影响旧版本读取（旧版本忽略）。

## Data Model

### 数据库（`harmony_rss.db`，v6 → v7）

**`articles` 新增列**

| 列 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| link_key | TEXT | '' | URL 归一化键 |
| title_key | TEXT | '' | 标题归一化键 |
| canonical_id | TEXT | '' | 空 = 主条；非空 = 所属主条 id |

**新增索引**

- `idx_articles_link_key ON articles(link_key)`（仅非空值有意义）
- `idx_articles_title_key ON articles(title_key, published_at)`
- `idx_articles_canonical ON articles(canonical_id)`

### 领域模型（`model/Dedupe.ets` / `model/Feed.ets`）

- **Article 扩展**：`canonicalId: string`、`duplicateCount: number`（主条展示用）、`linkKey` / `titleKey`（写入时使用，不参与 UI）。
- **DedupeCandidate**：id / feedId / canonicalId / linkKey / titleKey / publishedAt。
- **DedupeMatch**：canonicalId / matchedBy（url / title）。
- **GroupSource**：articleId / feedTitle / link / publishedAt。

## Contracts & Interfaces

### DedupeKeys（纯函数）

- `urlKey(rawUrl: string): string`
- `titleKey(rawTitle: string): string`
- `sameTitleWindow(a: number, b: number): boolean`（±24h，0 值用入库时间由调用方传入）

### DedupeService（新增）

- `findMatches(candidates: DedupeCandidate[], incoming: DedupeCandidate[]): Map<string, string>`（incoming id → canonical id）
- `resolveRoot(candidate, existingById): string`（重复项解析到根主条）
- `groupIds(articleId: string): Promise<string[]>`：主条 + 全部重复项
- `expandIds(ids: string[]): Promise<string[]>`
- `applyRead(ids, value)` / `applyStarred(ids, value)` / `applyHidden(ids, value)` / `applyTag(tagId, ids)`：展开后批量落库
- `promoteIfNeeded(removingIds: string[]): Promise<void>`：删除/清理前提升主条
- `pickPromotion(candidates: DedupeCandidate[]): string`（纯函数，便于单测）

### ArticleStore（扩展）

- `migrate()` v7：加 3 列 + 3 索引；最新版本 IF NOT EXISTS 自愈。
- `insertNew(articles): Article[]`：计算键 → 批量匹配 → 写入 canonical_id；重复项不写 FTS/CJK；返回真新增。
- `insertRemote(articles, mappings): Promise<Article[]>`：同上（远端映射照常写入）。
- `loadGroupSources(articleId): Promise<GroupSource[]>`
- `groupIdsOf(id): Promise<string[]>`
- `promoteCanonical(id)` / `reassignDuplicates(oldRoot, newRoot)`
- `excludeDuplicates`：列表 SQL 增加 `canonical_id = ''`；搜索/标签/计数同样排除。

### 状态操作改造

- `FeedViewModel`：`toggleRead` / `toggleStar` / `markReadMany` / `markStarredMany` / `markFinished` / `setHidden` 改为经 `DedupeService` 展开；`recomputeUnread` / `archivedCount` / `collectFeedArticles` / `hiddenCount` 排除重复项。
- `RemoteSyncService`：新增 `enqueueGroupState(articleId, read?, starred?)`；状态回写解析主条后整组更新。
- `RuleService`：`applyToNew` 前将计划 id 展开为组 id；命中统计只按主条累加。

### UI 契约

- `ArticleListItem`：`article.duplicateCount > 1` 时显示「N 个来源」chip。
- `ArticleDetailView`：加载 `loadGroupSources`，在主标题下展示来源列表（源名 + 打开链接），仅 >1 时显示。
- `SettingsTabView`：新增「跨源去重」开关（默认开），说明文案。

### 资源契约

- 文案 key 前缀 `dedupe_*`；中英成对；尺寸复用现有 chip / row。
