# Feature Specification: 统一下拉菜单组件（AppMenu）

**Created**: 2026-11-02
**Status**: Implemented
**Input**: 用户提供两张截图 —— 图 1 首页排序弹窗（两组设置同时高亮、高亮块内缩小方块），图 2 设置页「外观与语言」主题弹窗（圆角卡片、单高亮、品牌色文案）。要求图 1 参考图 2 实现，并把 app 中的这类弹窗抽离成可重用组件。

## Overview

改造前全工程有 14 处 `bindMenu`，写法分三类：

- 设置页 / 订阅设置页 / 存储页三处各写了一遍「圆角高亮行 + 手绘 Divider」的选项菜单（几乎逐字重复）；
- 阅读页排序菜单自绘行，两组独立设置挤在一个平铺菜单里，**两行同时高亮**，高亮块靠 `margin` 内缩成小圆角方块；
- 其余 8 处直接吃系统 `MenuItem`，其中 5 处没设宽度，菜单会按系统「两列宽」撑到接近满屏。

本次把菜单的**数据描述**与**渲染**分离：调用点只描述「有哪些项、哪些项选中、点了做什么」，渲染集中在 `common/components/AppMenu.ets`，视觉基线取自图 2。

## Requirements

- **FR-001**: 新增纯数据模型 `common/components/MenuSpec.ets`（`MenuItemSpec` / `MenuSectionSpec` / `MenuSpec`），不依赖 ArkUI 渲染，可单测。
- **FR-002**: 新增唯一渲染入口 `common/components/AppMenu.ets`（全局 `@Builder`），全工程只在这里出现 `Menu()` / `MenuItem`。
- **FR-003**: 视觉统一：菜单宽度 220vp、卡片圆角 20vp、行高 48vp、高亮块铺满行宽（圆角 16vp）、选中项品牌色 + Medium、危险项危险色、禁用项 opacity 0.4 且点击不关闭菜单、前置图标 22vp。
- **FR-004**: 首页排序菜单拆成「排序」「分组」两个分区，各带小标题、各自只有一个高亮行（新增 `menu_section_sort` / `menu_section_group` 两条文案，覆盖 7 个语言）。
- **FR-005**: 选择型菜单（设置 / 订阅设置 / 存储 / 远程自动同步 / 远程服务类型）回填当前选中项；远程自动同步与远程服务类型两处原本没有选中态。
- **FR-006**: 全部 14 处 `bindMenu` 迁移到 `AppMenu`；删除类动作统一危险色；所有菜单都注入 `MaterialController.menuOptions(...)` 沉浸材质。
- **FR-007**: 只允许状态管理 V2；不新增多参 `@Builder`（多参不随状态刷新）。
- **FR-008**: 动态菜单项 id 必须在一张菜单内唯一（`ForEach` key），分组名统一 `group:` 前缀。

## Acceptance

- 首页排序弹窗 = 圆角卡片 + 两个带小标题的分区，每区单高亮，品牌色文案；与图 2 视觉一致。
- 全工程 `Menu() {` 只出现在 `common/components/AppMenu.ets`。
- 14 处菜单的宽度、圆角、行高、选中态、危险色、禁用态、图标一致；5 处原本「两列宽」的菜单收成 220vp。
- `MenuSpec` 单测通过；`devecocli check arkts`、构建、CodeLinter、`tools/check-i18n.mjs`、纯 V2 自查全部通过。
- 暗色主题与沉浸材质开关两个维度截图复核通过（`resources/dark` 已覆盖高亮色）。
