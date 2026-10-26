# Implementation Plan: 诊断与性能

## Source Changes

- 新增 `model/Diagnostics.ets`：耗时样本、失败五类归因、退出原因分类、最慢源排序 / 平均耗时（纯函数）。
- 新增 `service/DiagnosticsService.ets`：
  - `@ObservedV2` 运行时状态（启动、抓取、帧率、退出原因）；
  - 独立偏好库 `hds_diagnostics_v1`（只存聚合值与最近帧率，不存文章 / URL）；
  - `markLaunch / markFirstScreen / beginFetch / recordFeed / endFetch / recordFrameSample / clear`。
- 新增 `service/FrameRateSampler.ets`：`displaySync` 帧回调，2 秒窗口 + 30 秒限频。
- 修改 `entryability/EntryAbility.ets`：记录 `launchUTCTime`、`lastExitReason`、`lastExitMessage` 并初始化偏好库。
- 修改 `pages/Index.ets`：首屏后 `setTimeout(0)` 记录首屏耗时。
- 修改 `viewmodel/FeedViewModel.ets`：`fetchFeeds` 逐源采样并汇总。
- 修改 `views/HomeTabView.ets`：`onScrollStart` 触发帧率采样，离开页面停止。
- 新增 `views/DiagnosticsView.ets`：启动 / 抓取 / 失败归因 / 最慢源 / 源健康 / 运行时 / 记录开关。
- 修改 `RouterConstants` / `Index` / `SettingsTabView`：新增路由与「设置 → 系统」入口。
- 修改 `AppSettings` / `PreferencesConstants` / `SettingsStore`：诊断开关持久化。
- 测试：`Diagnostics.test.ets` + `List.test.ets`。

## Decisions

- **不拦截崩溃**：只读系统给的 `lastExitReason`。若注册 `errorManager.on('error')`，应用不再按默认行为退出，
  反而会把崩溃变成静默半残；诊断页只需要「上次为什么退出」，不需要接管崩溃。
- **独立偏好库**：诊断数据与设置分离，清除诊断不会误伤用户设置；只存数字聚合值。
- **帧率采样限频**：`displaySync` 连续开回调有耗电成本，因此只在滚动开始时开 2 秒、30 秒最多一次。
- **失败归因五类**：错误码（超时 / 网络 / HTTP / 内容 / 其他）比原始异常文案更适合展示与汇总。
- **内存有界**：单轮最多 500 个逐源样本；最慢源只取前 3，避免大批量订阅时占内存。
- **不上报**：不接入统计 / 崩溃 SDK，不开网络请求；页面明确说明数据仅在本机。
