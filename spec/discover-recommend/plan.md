# Implementation Plan: 发现与推荐

## Source Changes

- 新增 `model/Discover.ets`：分类常量、`DiscoverFeed`、30 条内置精选目录（含标签与本地热度）。
- 新增 `service/DiscoverService.ets`：分类 / 关键词筛选、归一化已订阅判定、相似源本地打分。
- 新增 `service/RssHubRoutes.ets`：实例地址归一化、`RssHubKind`、常见站点路由推导（纯函数）。
- 新增 `views/DiscoverView.ets`：目录 / 推荐 / 热门榜 / 剪贴板导入 / RSSHub 路由助手。
- 修改 `pages/Index.ets` + `common/constants/RouterConstants.ets`：新增 `PAGE_DISCOVER` 路由。
- 修改 `views/SubscriptionsView.ets`：新增「发现」入口行。
- 修改 `model/AppSettings.ets` / `PreferencesConstants` / `SettingsStore`：持久化 RSSHub 实例。
- 修改中英文 `string.json`。
- 测试：`Discover.test.ets` + `List.test.ets`。

## Decisions

- **目录内置**：精选源以静态数据维护，避免运行时探测与后台请求；发现页可完全离线使用。
- **热度本地化**：`popularity` 是人工维护的固定值，只用于排序；不伪装成实时榜单、不联网统计。
- **相似源可解释**：仅用目录标签 + 已订阅源标题 / 地址中的主题词打分；没有信号时返回空，不硬推。
- **路由少而稳**：只覆盖路由稳定的站点，候选仍需用户点击订阅并真实抓取一次校验；不做「猜路由」。
- **不新增权限**：剪贴板读取沿用 `PasteButton` 安全控件；RSSHub 与目录订阅复用 `HttpClient` 既有网络链路。
- **实例可替换**：公共实例可能限流，允许自建；地址归一化后落偏好库，脏值回退 `https://rsshub.app`。
