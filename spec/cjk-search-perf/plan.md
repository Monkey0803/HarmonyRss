# Implementation Plan: 中文检索性能与分词正确性

**Input**: `spec/cjk-search-perf/spec.md`

## Summary

两条主线：
1. **修正分词配置**：删除 FTS 建表里非法的 `tokenize='icu zh_CN'`，分词器只通过 `StoreConfig.tokenizer` 提供；启动时用真实中文样本探测「文本 MATCH 是否可用」，把结论变成可诊断状态，而不是靠猜。
2. **中文索引确定性兜底**：新增一张 CJK 二元组 FTS 表（字 + 相邻二元组，覆盖标题/摘要/正文），**所有含中文的查询一律走这张表**，多字查询用二元组 AND + 子串复核；英文查询继续走原 FTS。这样中文检索不再依赖 ICU 是否生效，也不会退化为全表 `LIKE`。

## Technical Context

**Language/Version**: ArkTS / HarmonyOS SDK（工程 modelVersion 6.1.0）
**Primary Dependencies**: `@kit.ArkData`（relationalStore）、`@kit.ArkUI`
**State Management**: 沿用 State Management V2
**Storage**: relationalStore（`harmony_rss.db`，schema v2 → v3）
**Testing**: `entry/src/ohosTest`（hypium）+ `arkts_check` + `build_project`
**Target Platform**: HarmonyOS 手机 / 平板
**Project Type**: mobile-app（单 entry 模块）
**Performance Goals**: 1 万篇下双字中文查询 90% 首屏 < 300ms；单字 < 500ms
**Constraints**: 不引入外部分词库/动态库；不改搜索页交互与查询语法；失败必须降级可读
**Scale/Scope**: 1 万–5 万篇文章；新增 1 个纯函数服务、1 个索引表、1 个诊断接口

## Project Structure

### Documentation (this feature)

```text
spec/cjk-search-perf/
├── spec.md
├── plan.md              # This file
└── tasks.md
```

### Source Code (repository root)

沿用现有 MVVM 分层，仅动检索链路：

```text
entry/src/main/ets/
├── common/constants/
│   ├── RssConstants.ets            # 修改：SCHEMA_VERSION 2→3；新增 CJK 表名、grams 上限、诊断常量
│   └── PreferencesConstants.ets    # 不变（能力探测结果不落盘，每次启动探测）
├── service/
│   ├── CjkTokenizer.ets            # 新增：CJK 字/二元组生成、查询切分、FTS 表达式构造（纯函数）
│   ├── SearchPlan.ets              # 新增：把 SearchQuery 编译为「主索引 + 候选复核」查询计划
│   ├── ArticleStore.ets            # 修改：探测、双索引建表/同步/重建、CJK 检索路径、诊断信息
│   └── SearchStore.ets             # 修改：透传诊断/耗时（如需要）
├── model/
│   └── Search.ets                  # 修改：新增 SearchDiagnostics / SearchTiming
├── viewmodel/
│   └── StorageViewModel.ets        # 修改：读取诊断状态供存储页展示
├── views/
│   └── StorageView.ets             # 修改：新增「检索索引」诊断行（就绪/降级/条数）
└── resources/
    ├── base/element/string.json    # 新增诊断文案（英文）
    └── zh_CN/element/string.json   # 新增诊断文案（中文）

entry/src/ohosTest/ets/test/
├── CjkTokenizer.test.ets           # 新增：分词/查询表达式/复核条件
└── SearchPlan.test.ets             # 新增：单字/双字/多字/中英混合/特殊字符
```

**Structure Decision**: 继续沿用现有工程架构，不新增目录层级。新增的 `CjkTokenizer` / `SearchPlan` 都是纯函数服务，便于单测；所有 SQL 仍集中在 `ArticleStore`，不把索引逻辑散到 ViewModel。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
| --------- | ---------- | ------------------------------------ |
| 新增第二张 FTS 表 | 中文分词能力不可控，必须有确定性索引路径 | 只依赖 ICU：真机已证实建表失败；只靠 LIKE：万级文本不可控 |
| 查询计划拆成独立模块 | 单字/双字/多字/中英混合的分支复杂且需单测 | 全部塞进 ArticleStore：难测、易回归 |

## Research & Decisions

### R-01 分词配置方式

- **Decision**: 删除 `tokenize='icu zh_CN'` 建表子句；分词器只由 `StoreConfig.tokenizer` 提供（官方文档明确该字段就是 FTS 分词器配置入口）。
- **Rationale**: 真机日志已证实该子句建表失败（`14800021`），而 StoreConfig 路径未报错，说明官方路径可用且不该重复配置。
- **Alternatives considered**: 尝试其它 tokenize 参数形式（不同设备/版本兼容性不可控）；使用 `pluginLibs` 自定义分词（需额外动态库，超出本次范围）。

### R-02 中文分词能力探测

- **Decision**: 启动时创建临时 FTS 表，插入一条中文样本（如「鸿蒙系统开发」）并执行中文 MATCH；命中即判定「中文 FTS 可用」，否则「不可用」。结果写入诊断状态与日志，失败静默。
- **Rationale**: 只有真实 MATCH 才能证明分词有效；仅靠 `isTokenizerSupported` 已证明与真实行为不一致。
- **Alternatives considered**: 依赖配置回读（无公开 API）；不做探测直接走兜底（会浪费 ICU 能力，且无法诊断）。

### R-03 中文索引结构

- **Decision**: 新增 `articles_fts_cjk`，列为 `article_id UNINDEXED` + `grams`（空格分隔的「单字 + 相邻二元组」token 流），建表时显式 `tokenize='unicode61'`，确保预切分 token 不被再次切碎；覆盖标题、摘要、正文纯文本，单文档计入索引的字符上限由常量控制（默认 20000）。
- **Rationale**: 预切分 + 固定分词器让索引行为与设备能力解耦；单字与二元组可同时覆盖单字查询与多字查询。
- **Alternatives considered**: 仅索引二元组（单字查询漏召回）；trigram 分词（依赖 SQLite 版本且 2 字查询失效）；自建倒排表（行数与写放大不可接受）。

### R-04 查询编译规则

- **Decision**: 含 CJK 的查询走 CJK 索引：
  - 长度为 1 的中文片段 → 单字 token；
  - 长度为 2 → 二元组 token；
  - 长度 ≥ 3 → 所有相邻二元组 AND，并追加子串复核（`instr`）消除「不连续命中」；
  - 英文片段 → 追加 `LOWER(col) LIKE '%term%'` 复核（候选集已被中文索引收窄）；
  - 纯英文查询 → 继续走原 `articles_fts` MATCH。
- **Rationale**: 二元组 AND 能走索引且覆盖长词；子串复核保证正确性；混合查询无需双表 JOIN。
- **Alternatives considered**: 双表 INTERSECT（SQL 复杂、结果集去重成本高）；长词直接 LIKE（失去索引优势）。

### R-05 索引同步与迁移

- **Decision**: schema v2 → v3 新增 `articles_fts_cjk`；`insertNew` / `setReaderHtml` / `deleteMany` / `deleteByFeed` / 清理 / 恢复全部同步写两张索引；升级后后台分批重建 CJK 索引，可中断续建（记录已索引条数）。
- **Rationale**: 与现有双写模式一致；分批避免阻塞冷启动。
- **Alternatives considered**: 触发器同步（FTS5 与触发器组合在部分版本行为不一致）；懒建索引（首次搜索卡顿）。

### R-06 性能验证方式

- **Decision**: 在 `ArticleStore` 记录最近一次检索的「路径（fts/cjk/like）+ 耗时」，输出日志并暴露给诊断状态；不新增面向用户的压测入口。
- **Rationale**: 满足可观测与不打扰用户；真实 1 万篇压测可在设备上用现有数据观察日志。
- **Alternatives considered**: 内置压测页面（增加 UI 面与数据污染风险）；ohosTest 灌 1 万条（测试时长与主包覆盖风险）。

### R-07 降级与回滚

- **Decision**: CJK 表建表失败 → 中文查询回退到现有 LIKE 路径（功能可用）；迁移失败 → 不删库、降级启动、下次重试；索引重建失败 → 保留旧索引并记录状态。
- **Rationale**: 检索是高频路径，任何结构变更都不能导致应用不可用。
- **Alternatives considered**: 迁移失败即重建索引（可能长时间空索引）。

## Data Model

### 数据库（`harmony_rss.db`，v2 → v3）

**新增虚表 `articles_fts_cjk`**

| 列 | 类型 | 说明 |
| --- | --- | --- |
| rowid | 隐式 | FTS 主键 |
| article_id | UNINDEXED | 对应 `articles.id` |
| grams | 文本 | 空格分隔的单字 + 二元组 token 流 |

建表参数：显式 `tokenize='unicode61'`。若建表失败则 `cjkIndexReady=false`。

**索引状态（内存态，不落库）**

- `cjkFtsCapable: boolean`：探测结论。
- `cjkIndexReady: boolean`：CJK 表是否可用。
- `cjkIndexedCount: number`：最近一次统计的索引条数。
- `lastSearchPath: string` / `lastSearchMillis: number`：最近一次检索路径与耗时。

### 领域模型新增

**SearchDiagnostics**

- `mainIndexReady`、`cjkIndexReady`、`cjkFtsCapable`
- `mainIndexed`、`cjkIndexed`
- `lastPath`、`lastMillis`

**CjkQueryPlan**

- `expression: string`（送入 MATCH 的表达式）
- `postFilters: string[]`（需要 `instr`/`LIKE` 复核的关键词）
- `used: boolean`（是否走 CJK 索引）

## Contracts & Interfaces

### CjkTokenizer（新增，纯函数）

- `isCjkCode(code: number): boolean`
- `splitRuns(text: string): CjkRun[]`：把文本拆成「CJK 片段 / 非 CJK 片段」
- `grams(text: string, maxChars: number): string`：生成索引 token 流（单字 + 二元组，CJK 片段内）
- `queryTokens(term: string): string[]`：把查询词转换成 MATCH token（单字 / 二元组）
- `needsPostFilter(term: string): boolean`：长度 ≥3 的中文片段需要子串复核

### SearchPlan（新增，纯函数）

- `compile(query: SearchQuery): CjkQueryPlan`：产出台 MATCH 表达式与复核关键词
- `hasCjk(query: SearchQuery): boolean`
- `postFilterSql(plan: CjkQueryPlan, alias: string, args: ValueType[]): string`：生成复核 SQL 片段（仅描述契约，具体 SQL 在实现中产生）

### ArticleStore（扩展）

- `probeCjkFts(): Promise<boolean>`：临时表 + 中文样本 MATCH，探测后清理。
- `isCjkIndexReady(): boolean`
- `diagnostics(): Promise<SearchDiagnostics>`
- `search(query, offset, limit)`：含 CJK → CJK 索引 + 复核；纯英文 → 原 FTS；失败 → LIKE。
- `rebuildSearchIndex(onProgress)`：同时重建主索引与 CJK 索引（或分阶段回调）。
- `rebuildCjkIndex(onProgress)`：可单独重建。

### 迁移契约

- `SCHEMA_VERSION` = 3。
- v2 → v3：创建 `articles_fts_cjk`；启动后后台重建（分批 200 条）；失败保持 `cjkIndexReady=false`，不阻塞启动。
- 新装用户：建表后直接可用，首次插入即写两张索引。

### 诊断与 UI 契约

- `StorageViewModel` 新增 `diagnostics` 状态与 `refreshDiagnostics()`。
- `StorageView` 在「检索索引」分组展示：主索引状态、中文索引状态、中文分词能力、索引条数、最近检索路径与耗时。
- 新增文案 key：`search_diag_*`（中英成对）。
- 日志统一前缀 `CJKIDX`：`probe result`、`cjk index ready`、`search path`（含耗时）。
