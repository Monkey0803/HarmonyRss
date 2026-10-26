# 权限审计（2026-10）

| 权限 | 级别 / 授权 | 用途 | 申请时机 | 拒绝 / 不可用时的降级 |
| --- | --- | --- | --- | --- |
| `ohos.permission.INTERNET` | normal / system_grant | 订阅抓取、正文提取、图片内联、翻译、远端同步 | 装机授予 | 离线可读缓存；抓取 / 翻译提示网络错误 |
| `ohos.permission.GET_NETWORK_INFO` | normal / system_grant | 隐私页展示在线 / 离线 | 装机授予 | 查询失败按「离线」展示，不影响其它功能 |
| `ohos.permission.DETECT_GESTURE` | normal / system_grant | 智感握姿（悬浮栏跟手） | 装机授予 | 关闭握姿开关后不调用 |
| `ohos.permission.DLP_GET_HIDE_STATUS` | system_grant | 防窥保护读取系统隐藏状态 | 装机授予 | 防窥关闭时不调用 |

## 不需要 manifest 权限的能力

| 能力 | 机制 | 申请时机 | 说明 |
| --- | --- | --- | --- |
| 通知 | `notificationManager.requestEnableNotification` | 用户打开「新文章通知」或通知设置页申请授权时 | 拒绝后只展示引导，不重复弹窗 |
| 后台抓取 | `WorkSchedulerExtensionAbility` | 系统按 WorkScheduler 周期调度 | 无独立权限；用户可关闭自动刷新或在系统设置撤销 |
| 备份导出 / 导入 | `DocumentViewPicker` | 用户点击导出 / 导入时 | 只访问用户选择的 URI |
| 全局背景图 | `PhotoViewPicker` | 用户点击选择图片时 | 只复制到应用沙箱 |
| 剪贴板 | `PasteButton` 安全控件 | 用户点击粘贴时 | 不后台读取剪贴板 |
| 应用私有文件 | 沙箱 `fileIo` | 正常读写 | 不涉及外部存储 |
