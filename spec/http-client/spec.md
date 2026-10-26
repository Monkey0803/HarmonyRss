# Feature Specification: 统一网络层 HttpClient

**Created**: 2026-10-26
**Status**: Draft
**Input**: `TODO.md` 横切技术前置「网络层统一」。

## Overview

把当前 4 处各自调用 `@kit.NetworkKit` 的代码（订阅抓取、正文抓取、图片内联、Google Reader 远端服务）
收敛到一个 `HttpClient`：统一超时、重试、条件请求、User-Agent、系统代理、并发与按主机限流。
调用方只描述「请求什么」，不再重复处理底层选项与异常分类。

## Requirements

- **FR-001**: 提供统一入口 `httpClient`，支持 GET / POST / HEAD，文本与二进制两种响应。
- **FR-002**: 默认带 `User-Agent`；保留调用方显式设置的头（大小写不敏感）。
- **FR-003**: 默认使用系统代理（`usingProxy`），可按请求关闭。
- **FR-004**: 网络错误 / 超时 / TLS 错误分类为 `HttpError`，区分可重试与不可重试。
- **FR-005**: GET 默认重试 1 次；5xx / 429 按指数退避重试，非幂等方法默认不重试（调用方可显式开启）。
- **FR-006**: 支持 `Retry-After`（秒），并设上限避免长时间挂起。
- **FR-007**: 全局并发上限（默认 4），超出排队；可按请求设置同主机最小请求间隔。
- **FR-008**: 条件请求辅助：`If-None-Match` / `If-Modified-Since`；304 原样返回给调用方处理。
- **FR-009**: 响应提供大小写不敏感的 header 读取；200/4xx/5xx 均不默认抛错（由调用方按业务判定）。
- **FR-010**: 订阅 / 正文 / 图片 / 远端同步全部改走统一入口，行为与错误码语义保持兼容。

## Acceptance

- 订阅抓取仍支持 ETag / Last-Modified 条件请求与 304。
- 断网时抓取仍得到「网络错误」，超时仍得到「超时」；单次失败可自动重试。
- 图片下载仍能内联为 data URI；远端登录 / 同步 / 写入错误分类不变。
- 新增纯函数单测覆盖退避、重试状态、主机键、Retry-After、header 读取。
