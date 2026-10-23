# Implementation Plan: 本地规则引擎

**Input**: `spec/rules-engine/spec.md`

## Summary

新增「规则」能力：规则 = 关键词（AND）+ 匹配字段 + 来源范围 + 动作（已读/收藏/打标签/隐藏）+ 优先级。
文章**入库后**同步执行规则（本地抓取与远端同步都覆盖），动作只增不减、幂等；
「隐藏」通过 `articles.is_hidden` 实现，主列表排除但检索/已隐藏列表仍可见，不参与删除。

## Technical Context

**Language/Version**: ArkTS / HarmonyOS SDK（工程 modelVersion 6.1.0）
**Primary Dependencies**: `@kit.ArkData`（relationalStore）、`@kit.ArkUI`、`@kit.UIDesignKit`
**State Management**: 沿用 State Management V2
**Storage**: relationalStore（schema v5 → v6：`rules` 表 + `articles.is_hidden`）
**Testing**: `entry/src/ohosTest`（hypium）+ `arkts_check` + `build_project`
**Target Platform**: HarmonyOS 手机 / 平板
**Project Type**: mobile-app（单 entry 模块）
**Performance Goals**: 100 规则 × 200 篇匹配 < 500ms；单次入库不因规则明显变慢
**Constraints**: 仅新文章；动作只增不减；隐藏≠删除；失败不影响入库
**Scale/Scope**: 规则 ≤100、每规则关键词 ≤10；新增 1 张表、1 个列、3 个页面、1 个引擎服务

## Project Structure

### Documentation (this feature)

```text
spec/rules-engine/
├── spec.md
├── plan.md              # This file
└── tasks.md
```

### Source Code (repository root)

```text
entry/src/main/ets/
├── model/
│   ├── Rule.ets                      # 新增：Rule / RuleDraft / RuleTestResult / RuleAction / RuleField
│   └── Feed.ets                      # 修改：Article 增加 hidden
├── common/constants/
│   ├── RssConstants.ets              # 修改：SCHEMA_VERSION 5→6；规则表名/上限；ArticleFilter.HIDDEN
│   └── RouterConstants.ets           # 修改：PAGE_RULES / PAGE_RULE_EDIT / PAGE_HIDDEN
├── service/
│   ├── RuleStore.ets                 # 新增：规则 CRUD、排序、命中统计、试运行查询
│   ├── RuleEngine.ets                # 新增：纯匹配与动作聚合（可单测）
│   ├── RuleService.ets               # 新增：对入库文章执行规则（应用动作 + 刷新内存态）
│   ├── ArticleStore.ets              # 修改：v6 迁移；LIST/BODY 列含 hidden；setHiddenMany；按隐藏筛选
│   └── TagStore.ets                  # 复用：addToArticles 幂等打标
├── viewmodel/
│   ├── RuleViewModel.ets             # 新增：规则列表/编辑/试运行/已隐藏列表
│   └── FeedViewModel.ets             # 修改：入库后调用 RuleService；隐藏过滤与未读统计
├── views/
│   ├── RulesView.ets                 # 新增：规则列表（启用/优先级/命中统计/试运行）
│   ├── RuleEditView.ets              # 新增：规则编辑页（关键词/字段/来源/动作/标签）
│   ├── HiddenArticlesView.ets        # 新增：已隐藏文章列表 + 取消隐藏
│   ├── SubscriptionsView.ets         # 修改：新增「规则（N）」入口
│   └── HomeTabView.ets               # 不改筛选条（已隐藏从规则页进入）
└── pages/Index.ets                   # 修改：注册 3 个路由

entry/src/main/resources/
├── base/element/string.json          # 新增 rule_* / hidden_*（英文）
└── zh_CN/element/string.json         # 新增 rule_* / hidden_*（中文）

entry/src/ohosTest/ets/test/
├── RuleEngine.test.ets               # 新增：匹配、字段范围、来源范围、多规则顺序、幂等计划
└── RuleOrder.test.ets                # 新增：优先级排序与动作合并
```

**Structure Decision**: 沿用现有架构；匹配算法放 `RuleEngine`（纯函数），落库与动作放 `RuleService`，SQL 放 `RuleStore`。`ArticleStore` 仍是唯一 schema 迁移入口。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
| --------- | ---------- | ------------------------------------ |
| 新增 `is_hidden` 列 | 隐藏必须影响主列表与统计，但不能删除文章 | 用标签模拟隐藏：语义混淆、用户可见、检索难控 |
| 独立 RuleEngine / RuleService | 匹配逻辑需单测，动作会碰多个 Store | 全塞进 FeedViewModel：不可测、与抓取流程耦合 |

## Research & Decisions

### R-01 匹配语义

- **Decision**: 同一规则内多个关键词为 AND；字段为多选（标题/摘要/正文/作者），任一所选字段包含全部关键词即命中；来源范围为「全部」或指定源集合；大小写不敏感。
- **Rationale**: 简单、可预期、易解释；覆盖绝大多数「屏蔽/归档」场景。
- **Alternatives considered**: 正则（性能与安全风险、用户难写）；OR 语义（规则会过宽）。

### R-02 执行时机

- **Decision**: 在文章写入主表后立即执行：`FeedViewModel.commitFresh` 在 `insertNew` 之后、`reloadFromStore` 之前；`RemoteSyncService` 在 `insertRemote` 之后。执行完动作后统一重载/刷新。
- **Rationale**: 此时文章 id 已确定，动作可批量落库；不影响解析与网络阶段。
- **Alternatives considered**: 入库前执行（无 id，无法打标/隐藏）；定时批处理（延迟明显）。

### R-03 动作执行与幂等

- **Decision**:
  - 已读/收藏：收集 id → `ArticleStore.setReadMany` / `setStarredMany`（只置 true）；
  - 标签：`TagStore.addToArticles(tagId, ids)`（`INSERT OR IGNORE`）；
  - 隐藏：`ArticleStore.setHiddenMany(ids, true)`；
  - 多规则冲突：按优先级升序依次执行，动作累积；已读/收藏不会被规则改回 false。
- **Rationale**: 满足「全部执行 + 只增不减 + 幂等」。
- **Alternatives considered**: 后规则覆盖前规则（会让用户难以预测结果）。

### R-04 隐藏的过滤边界

- **Decision**: `loadForList` 仍返回全部文章（含 hidden），在 `FeedViewModel.passesFilter` 中过滤：
  - 非 `HIDDEN` 筛选时隐藏文章一律不显示（先于归档/未读判断）；
  - `HIDDEN` 筛选只显示隐藏文章（仅供 `HiddenArticlesView` 使用）。
  - 未读数、分组未读数、归档计数、单源列表均排除隐藏文章；检索不受影响。
- **Rationale**: 不改数据库读取路径，避免两套查询；同时保证隐藏文章仍可检索/可恢复。
- **Alternatives considered**: SQL 层排除（已隐藏列表需要另一套查询，重复代码）。

### R-05 规则统计与试运行

- **Decision**: 规则行存 `match_count`（累计命中篇数）与 `last_hit_at`；每次执行按实际命中文章数累加。试运行查询最近 500 篇，只调用 `RuleEngine` 统计，不写任何状态。
- **Rationale**: 满足可观测与「试运行零副作用」。
- **Alternatives considered**: 只记规则最后一次运行（无法判断长期效果）；试运行顺便执行（违反只读要求）。

### R-06 性能上限

- **Decision**: 正文匹配截断到前 20,000 字符；规则一次加载进内存复用；100 规则 × 200 篇的匹配在 ArkTS 层完成，批量动作按 Store 批量接口执行。
- **Rationale**: 正文可能很大，截断可避免单篇拖慢；批量落库减少事务次数。
- **Alternatives considered**: 每条规则一次 SQL LIKE（规则数 × 文章数的 SQL 扫描，慢）。

### R-07 来源与标签失效

- **Decision**: 规则引用的来源被删除时，匹配阶段直接跳过该来源条件（等价于不命中指定源）；标签被删除时跳过打标动作并记录一次 warn，不影响其它动作。
- **Rationale**: 保证规则执行不因配置漂移中断。
- **Alternatives considered**: 执行失败回滚整篇（会让入库失败，违反 FR-011）。

### R-08 升级与回滚

- **Decision**: schema v5→v6：`ALTER TABLE articles ADD is_hidden INTEGER DEFAULT 0` + `CREATE TABLE rules` + `CREATE INDEX idx_rules_priority`；最新版本也执行 IF NOT EXISTS 自愈；失败不删库、规则功能降级为空态。
- **Rationale**: 与既有版本化迁移一致，文章数据不受影响。
- **Alternatives considered**: 重建 articles 表（风险高、无必要）。

## Data Model

### 数据库（`harmony_rss.db`，v5 → v6）

**`articles` 新增列**

| 列 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| is_hidden | INTEGER | 0 | 规则隐藏标记，不参与删除 |

**`rules`**

| 列 | 类型 | 说明 |
| --- | --- | --- |
| id | TEXT PK | `rule_<ts>_<rand>` |
| name | TEXT | 名称（≤32） |
| enabled | INTEGER | 0/1 |
| priority | INTEGER | 越小越先执行 |
| keywords | TEXT | JSON 字符串数组（≤10） |
| fields | TEXT | 逗号分隔：title,summary,content,author |
| feed_ids | TEXT | JSON 字符串数组；空数组 = 全部来源 |
| actions | TEXT | 逗号分隔：read,star,tag,hide |
| tag_ids | TEXT | JSON 字符串数组（打标动作使用） |
| match_count | INTEGER | 累计命中篇数 |
| last_hit_at | INTEGER | 最后命中时间（毫秒） |
| created_at / updated_at | INTEGER | 毫秒 |

索引：`idx_rules_priority ON rules(priority, created_at)`。

### 领域模型（`model/Rule.ets`）

- `Rule`：id / name / enabled / priority / keywords[] / fields[] / feedIds[] / actions[] / tagIds[] / matchCount / lastHitAt。
- `RuleDraft`：编辑态（同上但不含统计字段）。
- `RuleTestResult`：scanned / matched。
- `RuleAction` / `RuleField`：字符串常量类（避免新增 enum 归一负担）。

**`Article` 新增字段**：`@Trace hidden: boolean = false`。

## Contracts & Interfaces

### RuleEngine（纯函数）

- `matches(rule: Rule, article: Article): boolean`（字段截断、大小写不敏感、来源范围）
- `plan(rules: Rule[], articles: Article[]): RulePlan`：返回 `readIds` / `starredIds` / `hiddenIds` / `tagHits`（`tagId -> ids`）/ `ruleHits`（`ruleId -> count`）
- `normalizeKeywords(raw: string): string[]` / `validateDraft(draft): string`（错误码文案 key）

### RuleStore（新增）

- `list(): Promise<Rule[]>`（按 priority 升序）
- `create(draft): Promise<Rule | undefined>` / `update(id, draft)` / `remove(id)`
- `setEnabled(id, enabled)` / `move(id, delta)`
- `recordHits(hits: Map<string, number>, at: number): Promise<void>`
- `sampleArticles(limit: number): Promise<Article[]>`（试运行用，轻量列）

### RuleService（新增）

- `applyToNew(articles: Article[]): Promise<RuleApplyResult>`：加载启用规则 → `plan` → 批量动作 → 记录统计 → 回写内存态（`article.read/starred/hidden`）→ 通知远程同步入队
- `testRun(ruleId: string, limit: number): Promise<RuleTestResult>`（只读）

### ArticleStore（扩展）

- `migrate()` v6：加列 + 建表 + 索引；自愈。
- `setHidden(id, hidden)` / `setHiddenMany(ids, hidden)`。
- LIST / BODY 读取列包含 `is_hidden`；`loadForList` 回填 `article.hidden`。
- `deleteMany` / `deleteByFeed` / `purgeTrash` 不变（规则不参与删除）。

### FeedViewModel（修改）

- `commitFresh`：`insertNew` → `ruleService.applyToNew(fresh)` → `reloadFromStore` → `publish`。
- `passesFilter`：先判断 hidden（HIDDEN 筛选只保留隐藏，其它筛选排除隐藏）。
- `recomputeUnread` / `archivedCount` / `collectFeedArticles`：排除隐藏。
- 新增 `hiddenCount()` 与 `setHidden(ids, hidden)`（已隐藏列表用）。

### 远程同步（修改）

- `RemoteSyncService` 在 `insertRemote` 成功后调用 `ruleService.applyToNew(articles)`，随后刷新列表。

### 路由与页面契约

| 路由 | 页面 | 入口 |
| --- | --- | --- |
| `PAGE_RULES` = `rules` | `RulesView` | 订阅页「规则（N）」 |
| `PAGE_RULE_EDIT` = `ruleEdit` | `RuleEditView` | 规则页新建/编辑 |
| `PAGE_HIDDEN` = `hiddenArticles` | `HiddenArticlesView` | 规则页「已隐藏（N）」 |

- `RulesView`：启停开关、优先级上下移、命中次数/最后命中、试运行结果、编辑/删除（删除需确认）。
- `RuleEditView`：名称、关键词（逗号分隔）、字段多选、来源（全部 / 多选订阅源）、动作多选（已读/收藏/隐藏/打标签）、标签多选、保存校验。
- `HiddenArticlesView`：列表（轻量列）+「取消隐藏」。

### 资源契约

- 文案 key 前缀：`rule_*`、`hidden_*`；中英成对。
- 复用现有 chips / row / menu 样式与 float，不新增颜色。
