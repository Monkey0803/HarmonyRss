# Implementation Plan: 播客 / 视频 enclosure

## Source Changes

- 新增 `model/Enclosure.ets`（类型 / 时长 / firstAudio / firstVideo）。
- 新增 `service/EnclosureCodec.ets`（落库 JSON、时长解析）。
- 修改 `RssParser` / `JsonFeedParser` / `ParsedArticle` / `Article` / `ArticleMapper`。
- 修改 `ArticleStore`：v8 `enclosures` / `media_progress` 列、`loadMediaQueue`、`setMediaProgress`。
- 新增 `service/MediaPlayerService.ets`（AVPlayer / AVSession / 长时任务 / 队列 / 进度）。
- 修改 `ArticleListItem`（媒体图标 + 时长）、`ArticleDetailView`（媒体 chip、菜单、迷你播放条、TTS 互斥）。
- 修改 `module.json5`（KEEP_BACKGROUND_RUNNING + audioPlayback）与隐私文档。
- 测试：`Enclosure.test.ets` + `List.test.ets`。

## Decisions

- 媒体附件以紧凑 JSON 存 `articles.enclosures`，避免新表与额外 join；`media_progress` 直接放文章表。
- 播放器用 AVPlayer；每首歌创建独立实例、切歌释放，避免状态机复用问题。
- 后台任务在播放时申请、暂停 / 停止时释放；AVSession 提供锁屏控制与元数据。
- 视频不内嵌（ArkWeb/Video 与现有 Web 正文层冲突），统一交系统播放器，失败退浏览器。
- 队列只放主条 + 未隐藏 + 有音频附件；「未听」= `media_progress = 0`。
