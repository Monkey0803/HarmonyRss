# Implementation Plan: 键盘快捷键与基础无障碍

## Source Changes

- `ArticleDetailView`：根 Stack + Reader Web 挂 `onKeyEvent`；`handleShortcut` 处理 j/k/m/s// /Esc。
- `HomeTabView`：List 可聚焦（`focusable` + `focusOnTouch` + `defaultFocus`），`/` 打开搜索。
- `ArticleListItem`：`accessibilityDescription` 输出已读 / 未读 / 已收藏状态。
- `SettingsTabView`：导航区展示快捷键提示。
- 新增中英文案 `a11y_article_*` / `shortcut_hint`。

## Decisions

- 兼容两套键值：真实 ArkUI 事件通常给 `KeyCode`（如 J=2026），自动化 / Linux 注入给 36 等；
  两者都接受，避免只在真机或只在测试环境可用。
- 不注册全局输入监听（需权限）；只挂页面 / Web 的 `onKeyEvent`，输入框聚焦时自然不劫持。
- 无障碍只补核心阅读路径与已有图标按钮标签；全量对比度审计仍留作后续。
