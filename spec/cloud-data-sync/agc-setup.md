# AGC 端云数据同步配置与验收对照

> T1.1，2026-11-03。本文记录仓库中可核实的端侧契约、Mate 70 Pro 单机登记结果，以及需要在 AGC 控制台复核的配置。`spec.md` / `tasks.md` 记载容器和数据类型已由用户配置；本轮未取得控制台截图，不能据此认定当前云侧字段、权限或签名绑定仍一致。

## 端侧契约

| 项 | 仓库中的值 | 核对位置 |
| --- | --- | --- |
| 应用包名 | `com.xiaohuihu.rss` | `AppScope/app.json5` |
| 系统云同步开关 | `cloudStructuredDataSyncEnabled: true` | `AppScope/app.json5` |
| 权限 | `ohos.permission.DISTRIBUTED_DATASYNC`，使用场景为 `EntryAbility` | `entry/src/main/module.json5` |
| 本地镜像库 | `harmonyrss_cloud.db`，安全级别 S1 | `CloudStore.ets` |
| 云容器 / 数据类型 | `harmonyrss_cloud` / `cloudSyncRecords` | `spec.md`、`CloudStore.ets` |
| 分布式登记 | `setDistributedTables(['cloudSyncRecords'], DISTRIBUTED_CLOUD, { autoSync: true })` | `CloudStore.ets` |
| 手动同步 | `cloudSync(SYNC_MODE_TIME_FIRST, ['cloudSyncRecords'])` | `CloudStore.ets` |

端侧写入的是 `SyncRecord` 镜像行；领域表仍在本地。`CloudRelayBackend` 分页读取镜像表，`SyncEngine` 合并后再回写。**`cloudSync()` 返回或本地表中有记录，均不能单独证明另一台设备已收到数据。**

## 字段逐一核对

AGC 中的 `cloudSyncRecords` 数据类型应与以下端侧定义逐列核对。表名和字段名大小写保持一致，不要把毫秒时间戳设为 32 位整数。

| 字段 | 本地 SQL 定义 | 写入值 | AGC 待核对类型 / 约束 |
| --- | --- | --- | --- |
| `recordKey` | `TEXT PRIMARY KEY` | `SyncRecord.key`，非空稳定键 | String；主键 |
| `kind` | `TEXT NOT NULL DEFAULT ''` | 记录类型 | String；非空 |
| `payload` | `TEXT NOT NULL DEFAULT ''` | JSON 文本 | String；非空；确认长度上限能容纳实际记录 |
| `updatedAt` | `TEXT NOT NULL DEFAULT '0'` | 毫秒时间戳的十进制字符串 | String；非空；不要用 Integer |
| `deleted` | `INTEGER NOT NULL DEFAULT 0` | `0` / `1` 墓碑标志 | Integer；非空 |
| `origin` | `TEXT NOT NULL DEFAULT ''` | 来源设备标识 | String；非空 |

本地查询按 `CAST(updatedAt AS INTEGER), recordKey` 升序续页；云侧字段类型变化会破坏这个契约。云侧字段与权限的最终值须以控制台实际部署内容为准。

## AGC 控制台核对单

1. 在与包名 `com.xiaohuihu.rss` 对应的 AGC 应用下，确认端云数据同步服务已开通，容器 `harmonyrss_cloud` 已部署且启用。
2. 打开数据类型 `cloudSyncRecords`，逐列与上表比对名称、类型、主键、必填属性及 `payload` 容量，并留存字段页截图。检查读写权限是否只覆盖预期的本应用用户；记录控制台实际策略，不在此预设权限值。
3. 核对当前安装包的签名证书与 AGC 应用绑定。仓库 `build-profile.json5` 只配置名为 `default` 的本机调试签名；**发布签名、发布证书指纹及 AGC 绑定尚无仓库证据**。发布包需单独复核，不能以调试包通过替代。
4. 真机登录华为账号，开启系统「云空间」中本应用的同步开关，再在应用内选择端云目标。记录 `CloudStore.isDistributed()`、`CloudAvailability`、`setDistributedTables` 的错误码和「立即同步」结果。成功标准是 `isDistributed() === true`，且手动同步无错误。
5. 在第二台同账号真机上核对至少一条记录变化，记录两端时间和状态；这属于 T1.6 双设备验收，T1.1 的单机登记成功不能替代它。

不要用应用内「重置模拟远端」或清空云表来排查配置：这会改变同步数据。

## 当前证据与待补项

| 检查 | 当前结论 | 待补证据 |
| --- | --- | --- |
| 端侧包名、开关、权限、六列建表和登记调用 | 已从当前源码核对 | 构建产物及真机日志可在设备连接后复核 |
| AGC 容器与数据类型存在 | 既有 `spec.md` / `tasks.md` 记载用户已配置；本轮未登录控制台 | 容器及数据类型页面截图 |
| 云侧六列与读写权限一致 | 未验证 | 字段与权限页面截图 / 导出配置 |
| 调试签名可用于当前本机构建 | 已确认本机证书文件存在，主包构建通过 | AGC 绑定信息 |
| 发布证书和云权限绑定 | 未验证 | 发布证书指纹及 AGC 应用绑定截图（不要上传私钥或口令） |
| 真机分布式表登记 | Mate 70 Pro（`10.155.89.11:45679`）临时切换端云目标后，`CloudStore` 于 2026-11-03 16:12:37 记录 `cloud sync enabled for cloudSyncRecords`；该日志只在登记成功、`isDistributed` 置为 true 的分支产生 | 正式签名包仍需复核；双设备传输另见 T1.6 |

本次真机检查前，应用选择 Mock 目标、总同步关闭、待推送 0、已同步 0。只短暂切换同步目标，没有点击「立即同步」或主动写入记录；登记时使用 `autoSync: true`，不能仅凭界面计数排除系统处理已有云表行。检查后已恢复 Mock，计数仍为 0。界面证据：[端云目标](evidence/cloud-target-mate70pro-2026-11-03.png)、[恢复 Mock](evidence/restored-mock-mate70pro-2026-11-03.png)。仓库另有单机同步记录（`TODO.md` 记载手动同步 33 条、待推送 0），但本次没有重跑数据同步，因此不能据此判定双设备已收敛。
