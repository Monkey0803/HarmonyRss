---
name: xiaohuihu-rss-reader
description: 查询 HarmonyRss 本机已保存的 RSS 文章并打开指定文章
---

## 触发场景

用户明确要求在 HarmonyRss 中查找未读文章、已收藏文章，或按关键词查找并打开文章时调用。
不用于联网搜索新闻、总结正文、修改已读或收藏状态。

### 场景 1：查找文章（findArticles）

执行参数：`exec-cli(command: ohos-arkTSScript --skillName 'xiaohuihu-rss-reader' --scriptPath 'scripts/RssReaderSkill.ets' --functionName 'findArticles' --args '{"arg1":"鸿蒙","arg2":"unread"}')`

`arg1` 为可选关键词，最多 100 字符；`arg2` 为 `all`、`unread` 或 `starred`。两项不能同时为空或为 `all`。

```json
{"args":{"type":"object","properties":{"arg1":{"type":"string","maxLength":100},"arg2":{"type":"string","enum":["all","unread","starred"]}}}}
```

执行返回值：成功时 `data.items` 最多五条，每条含 `articleId`、`title`、`source`。失败时 `errCode` 为 `ERR_INVALID_PARAMS`、`ERR_NOT_FOUND` 或 `ERR_INTERNAL`。

```json
{"type":"object","required":["type","status"],"properties":{"type":{"const":"result"},"status":{"enum":["success","failed"]},"data":{"type":"object"},"errCode":{"enum":["ERR_INVALID_PARAMS","ERR_NOT_FOUND","ERR_INTERNAL"]}}}
```

### 场景 2：打开文章（openArticle）

仅在用户从查找结果中选定一篇文章时调用；`arg1` 必须是上一场景返回的 `articleId`。

执行参数：`exec-cli(command: ohos-arkTSScript --skillName 'xiaohuihu-rss-reader' --scriptPath 'scripts/RssReaderSkill.ets' --functionName 'openArticle' --args '{"arg1":"文章 ID"}')`

```json
{"args":{"type":"object","required":["arg1"],"properties":{"arg1":{"type":"string","minLength":1,"maxLength":512}}}}
```

执行返回值：成功时 `data.articleId` 为已打开文章；失败时 `errCode` 与查找场景一致。

```json
{"type":"object","required":["type","status"],"properties":{"type":{"const":"result"},"status":{"enum":["success","failed"]},"data":{"type":"object"},"errCode":{"enum":["ERR_INVALID_PARAMS","ERR_NOT_FOUND","ERR_INTERNAL"]}}}
```
