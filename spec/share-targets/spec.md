# Feature Specification: 分享目标扩展

**Created**: 2026-10-22
**Status**: Draft
**Input**: `TODO.md` P1-6。用户已确认：第一版只做免 Key 的 URL Scheme/系统能力目标；三处入口；多模板 + 排序；高亮支持单篇/全部 Markdown。

## Overview

把现在零散的「系统分享 / 复制 / 浏览器」收敛为一个统一分享面板，并补齐常用稍后读/笔记服务
（Pocket、Instapaper、Flomo、邮件）与自定义分享模板；同时让高亮/笔记可导出为 Markdown。
所有投递都由用户主动触发，应用不自动上传任何内容。

## User Scenarios & Testing *(mandatory)*

### User Story 1 - 统一分享面板 (Priority: P1)

用户在详情页、列表或高亮页想分享内容，不希望每个地方一套菜单。

**Why this priority**: 统一入口是后续所有目标与模板的基础。

**Independent Test**: 从详情页、列表左滑、高亮页三处进入，看到同一套动作与目标。

**Acceptance Scenarios**:

1. **Given** 用户在某篇文章详情页，**When** 点击「分享」，**Then** 打开统一分享面板，包含系统分享 / 复制链接 / 复制正文 / 浏览器打开 / 稍后读 / 外部目标 / 模板。
2. **Given** 用户在列表左滑某篇文章，**When** 点击「分享」，**Then** 打开同一面板且上下文是该文章。
3. **Given** 用户在高亮页选中一条高亮，**When** 点击分享，**Then** 打开面板且分享内容为该条高亮（引文 + 备注 + 文章链接）。
4. **Given** 面板已打开，**When** 用户点击任意目标，**Then** 面板关闭并执行对应动作，成功/失败均有轻提示。

---

### User Story 2 - 内置目标投递 (Priority: P1)

用户希望一键把文章送到 Pocket / Instapaper / Flomo，或用邮件发给朋友。

**Independent Test**: 在已安装对应 App 的设备上点击目标，App 被拉起且 URL/标题正确；未安装时给出提示并回退复制链接。

**Acceptance Scenarios**:

1. **Given** 设备已安装 Pocket，**When** 点击 Pocket，**Then** 拉起 Pocket 并带上文章 URL 与标题。
2. **Given** 设备已安装 Instapaper，**When** 点击 Instapaper，**Then** 拉起并带上 URL 与标题。
3. **Given** 设备已安装 Flomo，**When** 点击 Flomo，**Then** 拉起并带上「标题 + 链接」内容。
4. **Given** 点击「邮件」，**When** 系统邮件可用，**Then** 打开写邮件界面并预填标题、链接与摘要。
5. **Given** 目标 App 未安装或拉起失败，**When** 点击该目标，**Then** 提示「未安装/无法打开」，并提供「复制链接」兜底。
6. **Given** 文章链接为空，**When** 点击需要 URL 的目标，**Then** 该目标禁用或提示无法分享。

---

### User Story 3 - 自定义模板与高亮导出 (Priority: P2)

用户有自己的分享格式（例如加话题标签、署名），并希望把高亮导出成 Markdown 存档。

**Independent Test**: 新建/编辑/排序模板并在面板中选择使用；单篇与全部高亮都能导出 Markdown。

**Acceptance Scenarios**:

1. **Given** 用户在设置中新建模板 `{title} — {url} #RSS`，**When** 保存，**Then** 面板中出现该模板。
2. **Given** 用户选择该模板，**When** 点击「复制」，**Then** 占位符被替换为当前文章内容并复制成功。
3. **Given** 用户调整模板顺序，**When** 重新打开面板，**Then** 顺序与设置一致。
4. **Given** 模板包含未知占位符或为空，**When** 保存，**Then** 给出提示并阻止保存（空模板）或忽略未知占位符（保留原文）。
5. **Given** 文章有 3 条高亮，**When** 选择「导出本篇高亮」，**Then** 生成包含标题、来源、链接、引文、备注、时间的 Markdown 文件。
6. **Given** 用户在高亮库点击「全部导出」，**When** 选择 Markdown，**Then** 生成包含全部高亮（按文章分组）的 Markdown 文件。

---

### Edge Cases

- 文章标题/摘要为空，或摘要里含 HTML 实体、换行。
- URL 含中文/空格/特殊字符（需编码）。
- 目标 App 已安装但拒绝打开（scheme 无响应）。
- 剪贴板写入失败。
- 模板很长（>2KB）或占位符重复多次。
- 高亮备注为空（只导出引文）。
- 高亮所属文章已被删除（仍能导出引文，标题/链接为空）。
- 系统分享面板不可用（无可用应用）。
- 多次快速点击目标，避免重复拉起/重复复制。

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: 系统 MUST 提供统一分享面板，详情页、列表、高亮页三处入口复用同一组件。
- **FR-002**: 面板 MUST 提供：系统分享、复制链接、复制正文、浏览器打开、加入稍后读。
- **FR-003**: 面板 MUST 提供内置目标：Pocket、Instapaper、Flomo、邮件（免 Key，URL Scheme / mailto）。
- **FR-004**: 目标投递 MUST 对 URL/文本做正确编码；MUST 在拉起失败时提示并回退复制链接。
- **FR-005**: 系统 MUST 支持自定义分享模板：名称 + 内容 + 排序；占位符至少包含 `{title}`、`{url}`、`{summary}`、`{author}`、`{tags}`。
- **FR-006**: 模板 MUST 持久化并在面板中按用户顺序展示；空模板 MUST 拒绝保存；未知占位符 MUST 原样保留。
- **FR-007**: 用户 MUST 能将模板结果复制到剪贴板或交给系统分享。
- **FR-008**: 系统 MUST 支持单篇高亮导出 Markdown（标题/来源/链接/引文/备注/时间）。
- **FR-009**: 系统 MUST 支持全部高亮导出 Markdown（按文章分组）；现有 JSON 导出 MUST 保留。
- **FR-010**: 所有分享动作 MUST 仅在用户触发时发生，不得自动上传内容或请求网络。
- **FR-011**: 面板打开 MUST 不阻塞列表/阅读；失败提示 MUST 可理解且可恢复。
- **FR-012**: 所有新增界面与提示 MUST 提供简体中文与英文。
- **FR-013**: 高亮导出内容 MUST 对 Markdown 特殊字符做转义，避免破坏结构。

### Key Entities *(include if feature involves data)*

- **分享上下文（ShareContext）**：文章 / 高亮 / 纯文本 + 来源，决定面板可用动作。
- **分享目标（ShareTarget）**：目标 id、名称、类型（system / scheme / mailto / clipboard / internal）、是否可用。
- **分享模板（ShareTemplate）**：名称、内容、排序位。
- **高亮导出项（HighlightExportItem）**：文章标题/来源/链接 + 引文/备注/时间。
- **模板占位符（TemplateToken）**：`title` / `url` / `summary` / `author` / `tags`。

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 从三处入口打开分享面板均不超过 2 次点击。
- **SC-002**: 在目标 App 可用的环境里，URL Scheme 目标投递成功率 100%。
- **SC-003**: 模板占位符替换正确率 100%（固定用例集：空字段、特殊字符、重复占位符）。
- **SC-004**: 单篇/全部高亮 Markdown 导出内容完整率 100%（标题/引文/备注/链接齐全）。
- **SC-005**: 分享面板打开到可交互 < 300ms。
- **SC-006**: 分享流程中除系统分享/浏览器外，应用不发起任何网络请求。

## Assumptions

- 第一版只做免 Key 目标；Readwise / Notion 等需 Token 的服务留到后续。
- URL Scheme 是否可用取决于目标 App 是否安装；未安装时回退复制链接，不视为失败。
- 模板占位符固定集合，不支持条件、脚本或自定义函数。
- 分享对象为单篇文章或单条高亮；批量分享文章不在本轮。
- 高亮 Markdown 复用现有 `HighlightExport` 数据与文件保存能力。
- 现有纯状态管理 V2、HDS 约束与构建约束继续有效。

## Open Questions

- 无关键未决项。自定义模板的存储位置（偏好库 / RDB）在实现阶段按现有设置存储方式决定。
