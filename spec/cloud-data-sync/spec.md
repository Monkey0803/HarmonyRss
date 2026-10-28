# Feature Specification: 端云数据同步（华为云空间）

**Created**: 2026-10-28
**Status**: Done（端侧已接；云侧需在 AGC 部署后生效）
**Input**: 用户选择「端云数据同步」路线，AGC 容器 `harmonyrss_cloud` / 数据类型 `cloudSyncRecords` 已配置

## Overview

用系统「云同步服务」承载同步记录：端侧建独立库 `harmonyrss_cloud.db`，表 `cloudSyncRecords`
登记为 `DISTRIBUTED_CLOUD`，由系统在登录同一华为账号的设备之间同步行。
现有 `SyncEngine` 通过新的 `CloudRelayBackend` 读写这张表，因此字段级合并、墓碑、先拉后推等语义全部复用。

不引入应用内登录 UI：身份就是设备的华为账号，用户可在「设置 > 云空间」自行关闭本应用的同步开关。

## AGC 侧（已配置）

- 容器：`harmonyrss_cloud`，本地数据库名 `harmonyrss_cloud`
- 数据类型 / 本地表：`cloudSyncRecords`
- 列：`recordKey`(String, 主键) / `kind`(String) / `payload`(String) /
  `updatedAt`(String，毫秒十进制) / `deleted`(Integer 0/1) / `origin`(String)
- 注意：云侧列只能加不能改删；`updatedAt` 用 String 是因为控制台没有 Long，Integer 会溢出

## Requirements

- **FR-001**: `app.json5` 开启 `cloudStructuredDataSyncEnabled`，用户在「设置 > 云空间」可见应用开关。
- **FR-002**: 端侧独立库 `harmonyrss_cloud.db`（S1），建表语句与 AGC 列一一对应；主键 `recordKey` 为业务稳定键。
- **FR-003**: 打开库后调用 `setDistributedTables(['cloudSyncRecords'], DISTRIBUTED_CLOUD, {autoSync:true})`；
      失败（未部署 / 无权限）只记日志，本地表仍可用，同步退化为本机。
- **FR-004**: `cloudData.setCloudStrategy(NETWORK, WIFI 或 WIFI+CELLULAR)` 跟随现有「仅 Wi-Fi」开关。
- **FR-005**: `CloudRelayBackend implements SyncBackend`：`pull` 按 `updatedAt` 游标取行，
      `push` 整行 upsert，`reset` 清空表；游标非法值按 0 处理。
- **FR-006**: 云端变更（同账号其他设备写入）通过 `on('dataChange', SUBSCRIBE_TYPE_CLOUD)` 触发一次
      自动同步（受 60s 节流约束）。
- **FR-007**: 手动「立即同步」在云端模式下先 `cloudSync()` 拉一轮云端行，再跑引擎合并。
- **FR-008**: 设置页新增「端云数据同步（实验）」开关；关闭时继续用本机 Mock 后端，本地数据不变。
- **FR-009**: 声明 `ohos.permission.DISTRIBUTED_DATASYNC`（含 reason / usedScene），仅在开启云端模式时调用相关接口。

## Acceptance

- 两台登录同一华为账号的设备：A 端标已读 → B 端收到云端变更通知并自动合并，列表状态更新。
- 断网 / 未登录华为账号：云端模式不报崩溃，只在本机云库读写，恢复后继续收敛。
- 关闭「端云数据同步」后回到 Mock 后端，本机数据与同步副本保留。
- 用户在「设置 > 云空间」关闭本应用同步后，应用不再上传任何数据。

## Out of Scope

- 应用内华为账号登录（Account Kit）：身份由系统账号承接，不做登录 / 多账号 UI。
- 云端历史版本 / 冲突提示 UI。
- 领域表（订阅、文章、高亮…）直接上云：仍以 `SyncRecord` 为同步单位。
