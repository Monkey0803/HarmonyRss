# Tasks: 应用图标（仅静态更换）

- [X] T001 替换分层图标前景 / 背景（1024×1024 PNG，AppScope 与 entry 两份一致）
- [X] T002 替换启动图 `startIcon.png`（1024×1024，与新图标同视觉）
- [X] T003 核对 `app.json5` / `module.json5` 的 `icon`、`startWindowIcon` 引用（均指向分层图标）
- [X] T004 移除 `AppIconService` 与动态图标调用，确认不新增权限
- [X] T005 应用内 logo 选择器只作用于应用内展示，更新七语言说明文案
- [X] T006 `build_project` / 真机安装启动验证
