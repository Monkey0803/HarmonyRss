# Implementation Plan: 分享目标扩展

**Input**: `spec/share-targets/spec.md`

## Summary

新增统一分享上下文与面板：详情页、列表左滑、高亮页三处复用同一 `ShareSheet`。
面板内提供系统分享 / 复制链接 / 复制正文 / 浏览器 / 稍后读、四个免 Key 外部目标
（Pocket / Instapaper / Flomo / 邮件）、自定义模板（多模板 + 排序）以及本篇高亮 Markdown 导出。
模板存偏好库；高亮 Markdown 复用现有 `HighlightExport`。

## Technical Context

**Language/Version**: ArkTS / HarmonyOS SDK（工程 modelVersion 6.1.0）
**Primary Dependencies**: `@kit.AbilityKit`（startAbility / mailto）、`@kit.ShareKit`、`@kit.BasicServicesKit`（pasteboard）、`@kit.ArkData`（preferences）
**State Management**: 沿用 State Management V2
**Storage**: preferences（`KEY_SHARE_TEMPLATES`）；无数据库结构变更
**Testing**: `entry/src/ohosTest`（hypium，纯函数）+ `arkts_check` + `build_project`
**Target Platform**: HarmonyOS 手机 / 平板
**Project Type**: mobile-app（单 entry 模块）
**Performance Goals**: 面板打开到可交互 < 300ms；模板渲染与复制无感知延迟
**Constraints**: 仅用户触发；不做网络请求；目标失败回退复制；不引入 Token 类服务
**Scale/Scope**: 模板 ≤20；新增 3 个服务、1 个面板、1 个设置页、3 处入口

## Project Structure

### Documentation (this feature)

```text
spec/share-targets/
├── spec.md
├── plan.md              # This file
└── tasks.md
```

### Source Code (repository root)

```text
entry/src/main/ets/
├── model/
│   └── Share.ets                      # 新增：ShareContext / ShareTarget / ShareTemplate / ShareResult
├── common/constants/
│   ├── PreferencesConstants.ets       # 修改：KEY_SHARE_TEMPLATES
│   ├── RouterConstants.ets            # 修改：PAGE_SHARE_SETTINGS
│   └── CommonConstants.ets            # 修改：模板/分享文本上限
├── service/
│   ├── ShareTargets.ets               # 新增：目标注册表与 URL 构造（scheme/mailto）
│   ├── ShareTemplates.ets             # 新增：模板 CRUD/排序/占位符渲染/校验（纯逻辑）
│   ├── ShareService.ets               # 新增：上下文构建、目标执行、降级、高亮导出
│   ├── ArticleActions.ets             # 复用：copyText / share / shareText / openInBrowser
│   └── HighlightExport.ets            # 复用：toMarkdown / toJson
├── viewmodel/
│   └── ShareViewModel.ets             # 新增：面板状态、目标可用性、模板列表
├── views/
│   ├── ShareSheet.ets                 # 新增：统一分享面板
│   ├── ShareSettingsView.ets          # 新增：分享与模板管理页
│   ├── ArticleDetailView.ets          # 修改：底栏/菜单新增分享入口
│   ├── HomeTabView.ets                # 修改：左滑新增分享
│   ├── HighlightsView.ets             # 修改：单条高亮分享入口
│   └── SettingsTabView.ets            # 修改：「分享与导出」入口
└── pages/Index.ets                    # 修改：注册 PAGE_SHARE_SETTINGS

entry/src/main/resources/
├── base/element/string.json           # 新增 share_* 文案（英文）
└── zh_CN/element/string.json          # 新增 share_* 文案（中文）

entry/src/ohosTest/ets/test/
├── ShareTemplates.test.ets            # 新增：占位符、转义、校验、排序
└── ShareTargets.test.ets              # 新增：URL 构造与编码
```

**Structure Decision**: 沿用现有架构。目标构造与模板渲染做成纯逻辑模块（可单测），执行与降级放 `ShareService`，UI 只消费 `ShareViewModel`。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
| --------- | ---------- | ------------------------------------ |
| 独立 ShareTargets / ShareTemplates | URL 编码与占位符替换需单测，且会持续新增目标 | 全塞进面板组件：不可测、改一个目标要动 UI |
| 模板存偏好库而非数据库 | 模板量小、无查询需求 | 新建表：为一个 JSON 列表增加迁移成本 |

## Research & Decisions

### R-01 外部目标与 URL Scheme

- **Decision**: 目标注册表内置：Pocket `pocket://add?url=…&title=…`、Instapaper `instapaper://x-callback-url/add?url=…&title=…`、Flomo `flomo://create?content=…`、邮件 `mailto:?subject=…&body=…`。统一走 `startAbility({action:'ohos.want.action.viewData', uri})`。
- **Rationale**: 无需 Key、无需网络；scheme 由目标 App 注册。
- **Alternatives considered**: 官方 API（需要 OAuth/Token，第一版排除）；系统分享（用户多一步选择）。

### R-02 目标失败与降级

- **Decision**: `startAbility` 抛错（未安装/无响应）→ 返回「未安装/无法打开」结果，提示并自动把链接复制到剪贴板；不视为崩溃或静默失败。
- **Rationale**: 满足 FR-004 与「未安装不算失败」。
- **Alternatives considered**: 只提示不兜底（用户还要手动复制）。

### R-03 分享上下文统一

- **Decision**: `ShareContext` 描述 `kind`（article / highlight / text）、标题、链接、摘要、作者、标签、正文、引文/备注。三处入口都构造该对象再打开面板。
- **Rationale**: 面板与目标只依赖统一结构，避免每个入口一套参数。
- **Alternatives considered**: 每个入口直接调具体目标（重复且难扩展）。

### R-04 模板存储与占位符

- **Decision**: 模板存 preferences（JSON 数组：id/name/content/sort）；占位符 `{title}` `{url}` `{summary}` `{author}` `{tags}`；未知占位符原样保留；空名称/空内容拒绝保存；模板上限 20。
- **Rationale**: 无需表结构；JSON 足够；与现有设置存储一致。
- **Alternatives considered**: RDB 表（过度设计）；只允许一个模板（不满足已确认需求）。

### R-05 模板渲染与 Markdown

- **Decision**: 渲染为纯字符串替换；文章分享时 `{tags}` 取本地标签并逗号连接；高亮上下文用引文/备注拼装默认文本。高亮 Markdown 复用 `toMarkdown`（已做转义与分组）。
- **Rationale**: 复用现有导出与转义，避免两套格式。
- **Alternatives considered**: 新写 Markdown 生成器（重复且易分叉）。

### R-06 单篇高亮导出

- **Decision**: 在文章上下文的面板中提供「导出本篇高亮」：读取该文章全部高亮 → 组装 `HighlightLibraryItem` → `toMarkdown` → 系统分享；无高亮时禁用并提示。
- **Rationale**: 满足 FR-008，同时复用现有导出。
- **Alternatives considered**: 只在标注页导出全部（无法按篇导出）。

### R-07 入口与组件复用

- **Decision**: `ShareSheet` 作为 `@ComponentV2` 面板，通过 `bindSheet` 在三个宿主中复用；上下文由宿主写入 `shareViewModel.context` 后打开。
- **Rationale**: 单一实现，避免三套菜单；与现有 `bindSheet` 使用方式一致。
- **Alternatives considered**: 每个页面自绘菜单（维护成本高）。

### R-08 剪贴板与反馈

- **Decision**: 复制成功/失败、目标拉起结果统一通过 `ShareResult` 返回，宿主用 Toast 提示；复制正文按现有 20000 字符上限截断。
- **Rationale**: 统一反馈，避免每个入口各写一套。
- **Alternatives considered**: 只在面板内提示（离开面板后不可见）。

### R-09 非目标

- **Decision**: 第一版不做 Readwise / Notion（需 Token）、不做批量文章分享、不做网络请求。
- **Rationale**: 控制范围与隐私面。
- **Alternatives considered**: 一并接入（Token 管理、错误处理复杂）。

### R-10 风险与回滚

- **Scheme 差异**: 各 App scheme 可能随版本变化；失败回退复制，不影响主流程。
- **编码**: 统一 `encodeURIComponent`，避免中文/空格破坏 URI。
- **回滚**: 模板存偏好库，清空 key 即恢复默认；面板为新增入口，移除不影响现有分享。

## Data Model

### 偏好库

**`KEY_SHARE_TEMPLATES`**（JSON 数组）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| id | string | `tpl_<ts>_<rand>` |
| name | string | ≤24 字符 |
| content | string | ≤2000 字符 |
| sort | number | 展示顺序 |

### 领域模型（`model/Share.ets`）

- `ShareContext`：kind / title / url / summary / author / tags[] / body / quote / note / articleId。
- `ShareTarget`：id / labelKey / type（system / scheme / mailto / clipboard / internal）/ requiresUrl。
- `ShareTemplate`：id / name / content / sort。
- `ShareResult`：ok / targetId / fallbackCopied / messageKey。

## Contracts & Interfaces

### ShareTargets（纯函数）

- `targets(): ShareTarget[]`（固定顺序）
- `buildUri(targetId: string, ctx: ShareContext): string`（编码后的 scheme/mailto；不支持返回空串）
- `encode(value: string): string`

### ShareTemplates（纯函数 + 存储）

- `render(template: ShareTemplate, ctx: ShareContext): string`
- `validate(name: string, content: string): string`（返回错误 key，空串=通过）
- `list(): Promise<ShareTemplate[]>` / `saveAll(list)` / `create(name, content)` / `update(id, name, content)` / `remove(id)` / `move(id, delta)`
- 默认模板：`{title}` 换行 `{url}`（首次使用无模板时提供）

### ShareService（新增）

- `articleContext(article: Article): Promise<ShareContext>`（补标签）
- `highlightContext(item: HighlightLibraryItem): ShareContext`
- `execute(targetId: string, ctx: ShareContext, ability: common.UIAbilityContext): Promise<ShareResult>`：
  - system / scheme / mailto → `startAbility` 或 ShareKit；
  - clipboard → `articleActions.copyText`；
  - internal → 稍后读（`feedViewModel.toggleSaved`）。
- `exportArticleHighlights(articleId: string, title: string): Promise<ShareResult>`
- `exportAllHighlights(): Promise<ShareResult>`（复用现有）

### ViewModel

- `ShareViewModel`：`context: ShareContext`、`templates: ShareTemplate[]`、`busy`、`open(ctx)`、`close()`、`targets()`、`runTarget(id)`、`runTemplate(id, copy: boolean)`、`exportThisArticle()`。

### UI 契约

- `ShareSheet`：分组展示「动作 / 外部目标 / 模板 / 高亮导出」；不可用目标置灰并说明原因。
- `ShareSettingsView`：模板列表、新建/编辑（名称 + 内容 + 占位符说明）、删除、上下移动。
- 入口：详情页底栏/菜单、列表左滑「分享」、高亮页单条分享；设置页「分享与导出」。

### 资源契约

- 文案 key 前缀 `share_*` / `tpl_*`；中英成对；尺寸复用现有 sheet / chip。
