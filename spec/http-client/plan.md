# Implementation Plan: 统一网络层 HttpClient

## Summary

新增 `service/HttpClient.ets`（纯逻辑 + 平台调用），把 `FeedService` / `ArticleContentService` /
`ImageCache` / `remote/GReaderClient` 的 `http.createHttp()` 全部替换为 `httpClient`。
默认值集中在 `HttpDefaults`，错误统一为 `HttpError`；重试/退避/限流为可单测的纯函数。

## Design

- `HttpOptions`：headers / body / 超时 / binary / maxRetries / retryServerErrors / minIntervalMs / usingProxy。
- `HttpResponse`：status / header(name) / text / bytes。
- `HttpError`：kind（timeout / network）、causeCode、retriable。
- 并发：全局信号量（默认 4），排队等待；按主机记录上次开始时间做最小间隔。
- 重试：`backoffMs(attempt)`（400ms 起、指数、上限 4s）；429 优先用 `Retry-After`（上限 10s）。
- 条件请求：`setConditionalHeaders(headers, etag, lastModified)`。
- 方法：`getText` / `getBytes` / `request(HttpMethod, url, options)`。

## Source Changes

- 新增：`entry/src/main/ets/service/HttpClient.ets`
- 修改：`service/FeedService.ets`、`service/ArticleContentService.ets`、`service/ImageCache.ets`、
  `service/remote/GReaderClient.ets`
- 测试：`entry/src/ohosTest/ets/test/HttpClient.test.ets` + `List.test.ets`

## Decisions

- 非 2xx 不抛错：远端服务需要读取 401/404/429 的具体语义，统一层只负责传输。
- POST 默认不重试：避免非幂等写操作重复执行；远端 edit-tag / login 由调用方显式开启 1 次。
- 不做自定义代理配置：当前平台只暴露系统代理开关，先满足「代理」能力。
- 保持既有错误映射：抓取仍是 TIMEOUT / NETWORK_ERROR；远端仍是 NETWORK / TLS。
