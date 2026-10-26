# Tasks: 统一网络层 HttpClient

- [X] T001 新增 `service/HttpClient.ets`：HttpOptions / HttpResponse / HttpError / 并发与限流 / 重试 / 默认头
- [X] T002 重构 `FeedService` 走 `httpClient.getText`，保留条件请求与 FeedError 映射
- [X] T003 重构 `ArticleContentService.fetchPage` 走统一层，保留 304 与错误映射
- [X] T004 重构 `ImageCache.download` 走 `getBytes`
- [X] T005 重构 `GReaderClient.send` 走统一层，保留 RemoteError 分类
- [X] T006 新增 `HttpClient.test.ets`（退避 / 重试状态 / 主机键 / Retry-After / header）并聚合
- [X] T007 `arkts_check` + 纯 V2 自查
- [X] T008 `build_project` 成功并启动真机
- [X] T009 更新 `README.md` / `TODO.md` 横切项
