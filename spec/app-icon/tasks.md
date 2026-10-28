# Tasks: 应用图标（仅静态更换）

- [X] T001 替换分层图标前景 / 背景（1024×1024 PNG，AppScope 与 entry 两份一致）
- [X] T002 启动图 `startIcon.png` 改为分层图标合成的圆角 logo（320×320，仅 logo 无文字）
- [X] T002b 真机冷启动截图确认：启动页只显示 logo，尺寸约 107vp，无文字
- [X] T003 核对 `app.json5` / `module.json5` 的 `icon`、`startWindowIcon` 引用（均指向分层图标）
- [X] T004 移除 `AppIconService` 与动态图标调用，确认不新增权限
- [X] T005 应用内 logo 选择器只作用于应用内展示，更新七语言说明文案
- [X] T006 `build_project` / 真机安装启动验证
