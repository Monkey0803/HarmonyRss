# T5.3 ArticleStore 拆分与性能基线

## 结构与兼容性

- 原 `ArticleStore.ets` 拆为 `ArticleDatabase`（同一 RDB 连接、建表与迁移）、`ArticleSearchStore`（查询、FTS 与诊断）、`ArticleRepository`（文章、离线、去重、回收站与文章备份）、`HighlightStore`（标注与备份）。`ArticleSchema` 集中原 SQL 常量和返回类型，`ArticleServices` 只装配单例。
- 订阅源、标签和同步模块复用 `articleDatabase` 的连接；文章与标签关联的备份操作归入 `TagStore`。所有主代码、技能脚本及 ohosTest 调用方已改用所属领域入口。
- 数据库文件名与 schema v10 不变；删除、恢复、备份与同步操作仍使用原来的 SQL 和事务边界。

## 基准口径

`SearchPerf.test.ets` 在独立临时 RDB 中写入 500 个订阅源、1 万篇文章及两张 FTS 索引。它保留原有同构 SQL 检索计时，并增加应用实际 `ArticleRepository.open`、`loadForList`、`search` 的计时。检索和列表均预热一次，再运行四轮并记录均值；测试结束删除临时库，不触碰用户数据。

前后对比使用**同一设备、相同 debug 构建模式**。搜索目标为 300 ms。原版 `0a02ab0` 在临时检出中加入相同基准用例和仅供测试的数据库名注入；原版业务逻辑未改动。下面是模拟器数据，真机仍需另测。

## 当前验证（2026-11-03）

| 检查 | 结果 |
| --- | --- |
| 改动前 debug 主包构建 | 通过（`scripts/harmony.sh build`） |
| 拆分后 debug 主包构建 | 通过（`scripts/harmony.sh build`） |
| 拆分后 ohosTest HAP 构建 | 通过（hvigor `--no-daemon`） |
| 七份语言包 key 检查 | 通过（1138 key） |
| 选定 8 个 `.ets` 静态检查 | 报告 `No errors found`，命令随后因本机 `spawn EPERM` 退出，不能记为完整通过 |
| 模拟器完整单测 | 原版与拆分版均 **473/473 通过**；测试后已重装拆分版主包 |
| 主包启动 | `aa start` 成功，模拟器截图可见阅读页；最新崩溃文件早于本轮运行 |
| 真机性能数值 | **待测**：当前 HDC 只列出 `127.0.0.1:5555` 模拟器 |

### 同机前后对比

设备：`emulator`，OpenHarmony 7.0.0.105，serial `127.0.0.1:5555`。均为 debug 测试 HAP，独立临时库、1 万篇文章、500 个订阅源；列表与搜索各预热一次、统计随后四轮均值。`open` 为打开已灌入数据的库的一次耗时。

| 路径 | 原版 `0a02ab0` | 拆分版工作区 | 差值 |
| --- | ---: | ---: | ---: |
| 打开数据库 | 75 ms | 53 ms | −22 ms |
| 列表加载 | 225 ms | 229 ms | +4 ms |
| 中文搜索 | 64 ms | 68 ms | +4 ms |
| 英文搜索 | 29 ms | 30 ms | +1 ms |

模拟器搜索达到 300 ms 目标；列表和搜索差异很小，未见明确退化。这些数值不能替代真机验收。

真机可用后安装测试 HAP、执行 `aa test`，记录 `OHOS_REPORT_RESULT` 与 `PERF production` 日志；随后重装 `entry-default-signed.hap`。重点复查文章增删与恢复、离线正文、检索、高亮、备份恢复和同步采集。真机达到 300 ms 目标及无退化仍待确认。
