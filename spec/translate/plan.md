# Implementation Plan: 正文翻译

## Source

- 新增 `common/constants/TranslateConstants.ets`（默认值 / 上限 / 服务 id）。
- 新增 `model/Translation.ets`（段落 / 结果 / 错误分类）。
- 新增 `service/TranslationPolicy.ets`：语言识别、目标语言、段落切分、批次、端点归一（纯函数）。
- 新增 `service/TranslationService.ets`：DeepL / LibreTranslate 请求、错误映射、缓存编排。
- 新增 `service/TranslationStore.ets`：独立 RDB 缓存（不与主库版本迁移耦合）。
- 新增 `service/TranslateSecretStore.ets`：API Key → Asset Store。
- 新增 `viewmodel/TranslationViewModel.ets`、`views/TranslateSheet.ets`、`views/TranslateSettingsView.ets`。
- 修改 `AppSettings` / `PreferencesConstants` / `SettingsStore` / `RouterConstants` / `Index` /
  `SettingsTabView` / `ArticleDetailView`。
- 测试：`TranslationPolicy.test.ets` 并聚合到 `List.test.ets`。

## Decisions

- 第三方服务：DeepL（支持一次多个 text）+ LibreTranslate 兼容（q 数组）。
- 源语言交给服务自动检测；本地识别只用于「是否已是目标语言」的短路。
- 缓存独立库：可整体清空，不触发主库升级；保留 90 天 / 最多 500 条。
- 正文过长截断到 20,000 字符，按 20 段 / 4,000 字符分批。
- 选段翻译不写文章缓存（一次性），但仍走同一套错误与隐私开关。
