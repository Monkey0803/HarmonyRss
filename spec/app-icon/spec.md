# Feature Specification: 应用图标（仅静态更换）

**Created**: 2026-10-28
**Status**: Done
**Input**: 用户决策 —— 当前只做静态更换，不接入动态图标服务

## Overview

桌面图标与启动图通过**随版本发布的资源**更换，不调用 AppGallery Kit 的图标管理接口，
也就不需要向运营申请「图标管理服务」、不产生任何权限申请。

## Requirements

- **FR-001**: 采用**分层图标**：`AppScope/resources/base/media/layered_image.json` 引用
      `background`（背景图）与 `foreground`（前景图），两层均 1024×1024 PNG。
- **FR-002**: `AppScope/app.json5` 的 `icon` 与 `entry/src/main/module.json5` 入口 UIAbility 的
      `icon` 都指向 `$media:layered_image`；同名资源以 AppScope 为准（构建时覆盖模块内同名文件）。
- **FR-003**: 启动页 `startWindowIcon` 使用 `$media:startIcon`：**由分层图标合成**的圆角 logo
      （背景渐变 + 白色 RSS 前景），320×320 px（系统按图片实际大小居中展示，3x 屏约 107vp），
      只展示 logo，**不含任何文字**。
- **FR-004**: 两份 `background` / `foreground`（AppScope 与 entry）内容保持一致，避免不同入口取到不同版本。
- **FR-005**: 不引入 `@kit.AppGalleryKit` 的 `appInfoManager`，不申请图标管理服务，不申请任何新权限。
      既有 `service/AppIconService.ets`（动态图标）已移除，应用内不存在任何 `appInfoManager` 调用。
- **FR-006**: 更换图标 = 替换上述 PNG + 随新版本发布；同一版本内图标保持不变。
- **FR-007**: 「外观与语言」里的 App logo 选择器只影响**应用内**展示，不再尝试切换系统桌面图标；
      说明文案改为「桌面与启动图标为静态资源，随应用版本更新」。

## Acceptance

- 安装后桌面图标为新的分层图标（蓝色渐变背景 + 白色 RSS 图形）。
- 冷启动启动图与新图标一致，无白屏闪烁或旧图残留。
- `module.json5` / `app.json5` 无 icon 相关告警，构建与安装通过。

## Out of Scope（明确不做）

- AppGallery Kit 动态图标（`queryDynamicIcons` / `selectDynamicIcon` / `disableDynamicIcon`）。
- 运行时备用图标（`bundleManager.setAlternateIcon` + `alternateIcons`）。
- 按节日 / 活动在同一版本内切换图标。
