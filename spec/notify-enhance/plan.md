# Implementation Plan: 通知增强

**Input**: `spec/notify-enhance/spec.md`

## Summary

把「一次固定 id 的聚合通知」升级为策略化通知系统：
- 统一入口 `NotifyService.notifyNew`，后台抓取与前台刷新共用；
- `NotifyPolicy` 负责过滤（源开关 / 关键词 / 已读 / 隐藏 / 重复项）与免打扰/摘要判定；
- 每源最多 3 条、总量最多 10 条，按 `groupName=feedId` 分组；单条带「已读 / 收藏」动作，点击直达文章；
- 免打扰期间入队，结束后合并补发；每日摘要每天一条；
- 新增「通知设置」页（免打扰、摘要、关键词、授权状态）。

## Technical Context

**Language/Version**: ArkTS / HarmonyOS SDK（工程 modelVersion 6.1.0）
**Primary Dependencies**: `@kit.NotificationKit`、`@kit.AbilityKit`（wantAgent）、`@kit.ArkData`（preferences）
**State Management**: 沿用 State Management V2
**Storage**: preferences（策略、关键词、队列、摘要状态）
**Testing**: `entry/src/ohosTest`（纯策略函数）+ `arkts_check` + `build_project`
**Target Platform**: HarmonyOS 手机 / 平板
**Project Type**: mobile-app（单 entry 模块）
**Performance Goals**: 100 篇新增的通知规划 < 10ms；不影响抓取耗时
**Constraints**: 仅本地策略；通知失败不影响抓取；权限拒绝可降级
**Scale/Scope**: 每源 ≤3 条、总 ≤10 条；队列 ≤50；关键词 ≤20

## Project Structure

### Documentation (this feature)

```text
spec/notify-enhance/
├── spec.md
├── plan.md              # This file
└── tasks.md
```

### Source Code (repository root)

```text
entry/src/main/ets/
├── model/
│   ├── Notify.ets                    # 新增：NotifyPolicy / NotifyQueueItem / NotifyPlan / NotifyItem
│   └── AppSettings.ets               # 修改：免打扰/摘要/关键词字段
├── common/constants/
│   ├── PreferencesConstants.ets      # 修改：通知策略/队列/摘要 key
│   ├── RouterConstants.ets           # 修改：PAGE_NOTIFY_SETTINGS
│   └── CommonConstants.ets           # 修改：通知上限
├── service/
│   ├── NotifyPolicy.ets              # 新增：关键词、免打扰、过滤与分组规划（纯函数）
│   ├── NotifyStore.ets               # 新增：队列 / 摘要状态 / 关键词的偏好读写
│   ├── NotifyService.ets             # 修改：按策略发布、分组、动作、队列补发、摘要
│   ├── DeepLink.ets                  # 修改：新增 ACTION_STAR
│   ├── SettingsStore.ets             # 修改：通知策略字段读写
│   └── ArticleStore.ets              # 修改：按 fetched_at 查当日新文章（摘要用）
├── viewmodel/
│   ├── NotifyViewModel.ets           # 新增：策略编辑、授权状态、测试通知
│   └── FeedViewModel.ets             # 修改：commitFresh 后调用通知（前台）
├── views/
│   ├── NotifySettingsView.ets        # 新增：通知设置页
│   └── SettingsTabView.ets           # 修改：入口
├── workscheduler/RssWorkScheduler.ets# 修改：后台通知 + 免打扰补发 + 摘要检查
└── pages/Index.ets                   # 修改：注册路由；处理 ACTION_STAR；回前台补发队列/摘要

entry/src/main/resources/
├── base/element/string.json          # 新增 notify_* 文案（英文）
└── zh_CN/element/string.json         # 新增 notify_* 文案（中文）

entry/src/ohosTest/ets/test/
├── NotifyPolicy.test.ets             # 新增：关键词/免打扰/过滤/分组上限
└── NotifyQueue.test.ets              # 新增：队列合并/限长/摘要日期
```

**Structure Decision**: 沿用现有架构。策略判断放纯函数 `NotifyPolicy`，偏好读写放 `NotifyStore`，发布与系统 API 交互留在 `NotifyService`。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
| --------- | ---------- | ------------------------------------ |
| 独立 NotifyPolicy/NotifyStore | 策略组合（源/关键词/DND/上限）需要单测，发布逻辑需保持简单 | 全塞进 NotifyService：不可测、改动风险高 |
| 每源多条通知 | 用户需要单条动作与直达 | 只发一条聚合：无法单条处理 |

## Research & Decisions

### R-01 通知触发路径

- **Decision**: 后台 `RssWorkScheduler` 与前台 `FeedViewModel.commitFresh` 都调用 `notifyService.notifyNew(context, feeds, created)`；远端同步不通知（避免首次连接轰炸）。
- **Rationale**: 满足「后台 + 前台」，同时避免远端批量导入造成通知风暴。
- **Alternatives considered**: 远端也通知（首连可能上百条）。

### R-02 过滤规则

- **Decision**: 依次过滤：文章必须未读、非隐藏、非重复项 → 源有效通知（per-feed on/off，跟随全局）→ 关键词列表为空则通过，否则标题/摘要包含任一关键词（大小写不敏感）。
- **Rationale**: 与现有 per-feed notify 设置复用；关键词只扫标题/摘要保证性能。
- **Alternatives considered**: 扫描正文（入库耗时）；复用规则引擎（耦合大）。

### R-03 分组与限流

- **Decision**: 每条文章一条通知，`id = hash(articleId)`，`groupName = 'feed_' + feedId`；每源最多 3 条、全局最多 10 条；超出部分为每源发一条「还有 N 篇」聚合通知（无动作，点击打开该源列表）。
- **Rationale**: 支持单条动作与系统分组展开，同时避免刷屏。
- **Alternatives considered**: 只发一条（无单条动作）；全部发送（刷屏）。

### R-04 免打扰

- **Decision**: `dndEnabled` 默认 true，`start=23:00`、`end=08:00`（分钟数存储，支持跨午夜；起止相同视为关闭）。DND 内不发即时通知，文章 id 入队（最多 50）；在应用回到前台或下次后台任务时若已离开 DND，合并发一条「免打扰期间 N 篇新文章」。
- **Rationale**: 不丢信息、不夜间打扰。
- **Alternatives considered**: 直接丢弃（丢信息）；延后逐条补发（早间轰炸）。

### R-05 每日摘要

- **Decision**: `digestEnabled` 默认 false，`digestHour=20`。在回前台/后台任务完成时检查：当前小时 ≥ 设定值且 `lastDigestDate != 今天` 且当日有符合策略的新文章 → 发一条摘要并记录日期；只发一次。
- **Rationale**: 不依赖精准定时器，成本低。
- **Alternatives considered**: 注册每日 WorkScheduler（系统不保证准点，复杂度高）。

### R-06 通知动作与深链

- **Decision**: 复用 `DeepLinkParams`，新增 `ACTION_STAR='star'`；通知按钮 wantAgent 带 articleId + action。`Index.tryOpenDeepLink` 处理 markRead（现有）与 star（新增，调用 `markStarredMany` 并触发远端入队）。
- **Rationale**: 与现有深链机制一致，冷启动/前台都可处理。
- **Alternatives considered**: 通知内直接执行（Notification 无法调用应用逻辑）。

### R-07 权限与降级

- **Decision**: 设置页显示 `isNotificationEnabledSync()` 状态；开启时调用 `requestEnableNotification`；拒绝后只展示引导，不重复请求。任何发布失败只记日志。
- **Rationale**: 满足 FR-012，不影响抓取。
- **Alternatives considered**: 每次抓取都请求授权（骚扰）。

### R-08 摘要数据来源

- **Decision**: `ArticleStore.articlesFetchedSince(ts)` 查询 `fetched_at >= 当天 00:00` 的未读、非隐藏、非重复文章（轻量列），再走 `NotifyPolicy` 过滤。
- **Rationale**: 摘要关注「今天新到的」，与抓取时间一致。
- **Alternatives considered**: 按发布时间（时区/补抓不稳定）。

## Data Model

### AppSettings 新增

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| notifyDndEnabled | boolean | true | 免打扰开关 |
| notifyDndStart | number | 1380（23:00） | 分钟数 |
| notifyDndEnd | number | 480（08:00） | 分钟数 |
| notifyDigestEnabled | boolean | false | 每日摘要 |
| notifyDigestHour | number | 20 | 0–23 |
| notifyKeywords | string[] | [] | 关键词（≤20） |

### 偏好 key

- `KEY_NOTIFY_DND_ENABLED` / `KEY_NOTIFY_DND_START` / `KEY_NOTIFY_DND_END`
- `KEY_NOTIFY_DIGEST_ENABLED` / `KEY_NOTIFY_DIGEST_HOUR`
- `KEY_NOTIFY_KEYWORDS`（JSON 数组）
- `KEY_NOTIFY_QUEUE`（JSON：`[{articleId, feedId, at}]`，≤50）
- `KEY_NOTIFY_LAST_DIGEST`（YYYY-MM-DD）

### 领域模型（`model/Notify.ets`）

- `NotifyPolicy`：dndEnabled/start/end/digestEnabled/digestHour/keywords。
- `NotifyQueueItem`：articleId / feedId / at。
- `NotifyItem`：article / groupName / notificationId。
- `NotifyPlan`：items / overflowByFeed（feedId → 剩余条数）/ total。

## Contracts & Interfaces

### NotifyPolicy（纯函数）

- `inDnd(policy, minutesOfDay): boolean`（支持跨午夜）
- `matchesKeywords(article, keywords): boolean`（标题+摘要，大小写不敏感，空列表通过）
- `filter(articles, feeds, policy): Article[]`（源开关、已读、隐藏、重复项、关键词）
- `plan(items, maxPerFeed, maxTotal): NotifyPlan`
- `digestDue(policy, now, lastDigestDate): boolean`

### NotifyStore（新增）

- `loadPolicy(): NotifyPolicy` / `savePolicy(policy)`
- `loadQueue(): NotifyQueueItem[]` / `saveQueue(items)`（≤50，去重）
- `lastDigestDate(): string` / `setLastDigestDate(date: string)`

### NotifyService（改造）

- `notifyNew(context, feeds, added): Promise<void>`：策略过滤 → 免打扰入队 / 立即 plan+publish → 摘要检查。
- `flushQueueIfDue(context, feeds): Promise<void>`：离开 DND 后合并补发。
- `maybeSendDigest(context, feeds): Promise<void>`：每天一次。
- `publishItem(context, item, actions: boolean)`：单条发布（groupName、id、按钮）。
- `publishAggregate(context, feed, remaining)`：每源剩余聚合。
- `testNotification(context)`：设置页「发送测试通知」。
- 原有 `isEnabled` / `requestEnable` 保留。

### 设置与 UI

- `SettingsVM` 或 `NotifyViewModel`：setDndEnabled/setDndRange/setDigestEnabled/setDigestHour/addKeyword/removeKeyword/requestPermission/test。
- `NotifySettingsView`：授权状态、总开关、免打扰开关 + 起止时间（TimePickerDialog）、摘要开关 + 小时、关键词 chips + 输入、测试通知。
- `SettingsTabView`：新增「通知设置」入口（现有通知开关保留）。
- `Index`：`onPageShow` 调 `flushQueueIfDue` + `maybeSendDigest`；深链新增 star 动作处理。
- `RssWorkScheduler`：抓取后 `notifyNew`；结束时 `flushQueueIfDue` + `maybeSendDigest`。

### 资源契约

- 文案 key 前缀 `notify_*`；中英成对；时间格式用本地化字符串。
