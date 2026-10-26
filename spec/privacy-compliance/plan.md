# Implementation Plan: 权限与隐私合规

## Source Changes

- 新增 `service/NetworkStatus.ets`：只读默认网络状态（`hasDefaultNetSync`）。
- 新增 `viewmodel/PrivacyViewModel.ets`：通知授权 / 网络 / 翻译开关 / 缓存条数 / 远端账号状态。
- 新增 `views/PrivacyView.ets`：本机数据、外发数据、权限与授权、数据控制四块。
- 修改 `RouterConstants` / `Index` / `SettingsTabView`：注册 `PAGE_PRIVACY` 与设置入口。
- 修改 `entry/src/main/module.json5`：新增 `ohos.permission.GET_NETWORK_INFO`，补充权限注释。
- 新增 `PRIVACY.md`、`spec/privacy-compliance/permissions-audit.md`。
- 文案：base / zh_CN 各新增 `privacy_*`。

## Decisions

- 不引入统计 / 广告 / 埋点 SDK；隐私页只做本地状态聚合。
- 不为了「看起来完整」声明未使用的权限：存储 / 媒体 / 剪贴板都通过系统 Picker / PasteButton 访问。
- 网络状态用 normal 权限直接查询，不订阅变化（页面打开时读一次）。
- 通知保持运行时授权，不写 manifest；后台调度由 WorkScheduler 承担，无独立权限。
