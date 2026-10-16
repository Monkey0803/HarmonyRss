# AGENTS.md

## 项目
HarmonyOS (ArkTS) RSS 阅读器，使用 UI Design Kit（HDS）组件 + ArkUI 状态管理 V2。
模块：`entry`（主应用）、`entry/src/main/ets/form`（桌面服务卡片）。

## 硬性约束：只允许状态管理 V2

本工程**只支持纯状态管理 V2**，不接受任何 V1 写法。

### 允许（V2）
`@ComponentV2`、`@ObservedV2` + `@Trace`、`@Local`、`@Param`、`@Once`、`@Event`、
`@Monitor`、`@Computed`、`@Require`、`@Provider` / `@Consumer`、`@Builder`、`@BuilderParam`(仅在 V2 组件内传 builder)。

### 禁止（V1）
`@Component`、`@State`、`@Prop`、`@Link`、`@Provide`、`@Consume`、`@Observed`、`@ObjectLink`、
`@Watch`、`@Track`、`@StorageLink`、`@StorageProp`、`@LocalStorageLink`、`@LocalStorageProp`、
`@Entry(storage)`、`AppStorage`、`LocalStorage`、`PersistentStorage`。

### 迁移对照
| V1 | V2 |
| --- | --- |
| `@Component` | `@ComponentV2` |
| `@State` | `@Local`（需外部初始化的用 `@Param` / `@Param` + `@Once`） |
| `@Prop` | `@Param` |
| `@Link` | `@Param` + `@Event` |
| `@Observed` / `@ObjectLink` / `@Track` | `@ObservedV2` + `@Trace` |
| `@Provide` / `@Consume` | `@Provider` / `@Consumer` |
| `@Watch` | `@Monitor` |
| `AppStorage` | `AppStorageV2` |
| `PersistentStorage` | `PersistenceV2` |
| `LocalStorage` | `@ObservedV2` / `@Trace`（或 V2 状态容器） |
| 无 | `@Computed`（计算属性） |

### 第三方 / 系统组件的 V1 陷阱
引用外部组件前先确认它是不是 V1 `@Component`：

- **禁止 `HdsListItem`**（HDS，V1 `@Component`，内部用 `@BuilderParam`）。用它不仅违反纯 V2，
  且当它作为 `List` 直接子节点时 `customItemBuilder` 回调里的 `this` 会丢失
  （`this.article` 为 undefined，启动即崩溃）。
  列表行请用 **自绘 `@ComponentV2`**，横滑用 ArkUI 原生 `ListItem.swipeAction({ end: ... })`。
- 已确认可用（非 V1）：`HdsActionBar`（`@ComponentV2`）、`HdsSnackBar` / `HdsVisualComponent`（纯 API）。

### 服务卡片（form）
卡片入口组件使用 `@Entry @ComponentV2`，**不要**创建 / 传入 `LocalStorage`。
卡片提供方仍用 `updateForm` 推送数据，V2 下**按变量名匹配**字段 —— 因此
`@Local` 的变量名必须与 `updateForm` 数据里的 key 完全一致（如 `unread` / `t1` / `t2` / `t3`）。

### 自查命令
```sh
rg -n --glob '!**/build/**' --glob '*.ets' \
  "^\s*@Component\s*$|@State\b|@Prop\s|@Link\b|@Provide\b|@Consume\b|@Observed\b|@ObjectLink|@Watch\(|@Track\b|@BuilderParam|@StorageLink|@StorageProp|@LocalStorageLink|@LocalStorageProp|@Entry\(|AppStorage\.|LocalStorage|PersistentStorage|HdsListItem" \
  entry/src/main/ets AppScope
```
输出为空即符合纯 V2 要求。

## 常用命令
- 静态检查（.ets）：`arkts_check`
- 构建：`devecocli build`
- 部署运行：`devecocli run --skip-build --device "<device>"`
- 截图确认 UI：`devecocli ui screenshot --device "<device>" --path <file.png>`
  （`verify_ui` 在未配置多模态模型时不可用，改用截图 + 人工读图）
- 设备日志 / 崩溃：`devecocli log --device "<device>" --crash`
