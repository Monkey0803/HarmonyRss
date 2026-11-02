# Implementation Plan: 统一下拉菜单组件（AppMenu）

## Source Changes

**新增**
- `entry/src/main/ets/common/components/MenuSpec.ets`：`MenuItemSpec`（id / label / action + 选中 / 危险 / 禁用 / 图标）、`MenuSectionSpec`（分区 + 可选小标题）、`MenuSpec`（分区列表 + 宽度），纯数据。
- `entry/src/main/ets/common/components/AppMenu.ets`：`MenuRow` / `MenuRows` / `@Builder AppMenu(spec)`，唯一渲染菜单的地方。
- `entry/src/main/ets/common/components/ChoiceMenu.ets`：`choiceMenu(choice: ChoiceSet, currentId, onPick)`，把选项表转成选择型菜单（单独成文件，使 `MenuSpec` 零依赖、可单测）。
- `entry/src/main/ets/common/components/ChoiceField.ets`：`@Builder ChoiceValueChip(label)`，抽出三处重复的「当前值 + 倒三角」胶囊。
- `entry/src/ohosTest/ets/test/MenuSpec.test.ets`：规格模型单测（默认值 / 链式修饰 / 分区保序 / 首选中 id / 自定义宽度），并注册进 `List.test.ets`。

**修改**
- `entry/src/main/ets/views/HomeTabView.ets`：`SortMenu` 改为两分区（排序 / 分组）+ `sortMenuSpec()`；删除 `MenuItemRow`。
- `entry/src/main/ets/views/settings/SettingsRows.ets`、`FeedSettingsView.ets`、`StorageView.ets`：删除三份重复的 `ItemContent` / `OptionMenu` / `needDivider`，改 `choiceMenu(...)` + `ChoiceValueChip`。
- `entry/src/main/ets/views/RemoteServiceView.ets`：`ServiceTypeMenu` / `AutoSyncMenu` 补选中态，`LogoutMenu` 转动作菜单；三处补齐材质注入。
- `entry/src/main/ets/views/AddFeedPanel.ets`：`GroupMenu` 两分区（分组选择 / 新建分组），当前分组高亮。
- `entry/src/main/ets/views/SubscriptionsView.ets`：`BulkGroupMenu` / `FeedMenu` 转 `AppMenu`；删除项危险色。
- `entry/src/main/ets/views/ArticleDetailView.ets`：`ActionsMenu` 全量迁移（图标 / 禁用态 / 条件项保持原样），删除 `symbolStartIcon` 版 `menuIcon()`。
- `entry/src/main/ets/views/SmartFoldersView.ets`、`ShareSettingsView.ets`、`TagsView.ets`、`ShareSheet.ets`：行内动作菜单迁移，删除项统一危险色。
- `entry/src/main/resources/{base,zh_CN,zh_Hant,ja,de,fr,es}/element/string.json`：新增 `menu_section_sort` / `menu_section_group`。
- `entry/src/main/resources/base/element/float.json`：新增 `radius_menu` = 20（菜单卡片圆角）。`radius_menu_item`（8vp）保留 —— 它仍被 ArticleDetailView / SearchView / ArticleListItem 的非菜单控件引用，迁移后菜单本身不再使用它。

## Decisions

- **渲染入口唯一**：`Menu` / `MenuItem` 只写一次，避免第四个「选项菜单」实现再次出现；菜单宽度也由组件统一，不再由调用点各自决定（此前 5 处漏设宽度导致近满屏）。
- **全局 `@Builder` 而非自定义组件**：菜单内容纯展示、无生命周期需求（CodeLinter `@performance/avoid-overusing-custom-component-check`），且 `Menu` / `MenuItem` 本身只能挂在 `bindMenu` 的 builder 上。所有 builder 单参或无参，规避「多参 @Builder 不刷新」。
- **分区用 `MenuItemGroup`**：`Menu` 子节点只允许 `MenuItem` / `MenuItemGroup`，分区小标题只能走 `MenuItemGroup({ header })`；分隔线统一 `menuItemGroupDivider` 成 `hm_divider`。单分区菜单不套 group，避免出现无意义分隔线。
- **高亮块铺满行宽**：旧实现用 `margin` 内缩 + 8vp 圆角，视觉上是「小方块」；且 100% 宽度加外边距会在右侧溢出（旧代码注释记录过）。改为整行铺满 + 16vp 圆角，卡片 20vp，形成内小外大。
- **排序菜单分区**：两组独立设置共用一张平铺菜单必然出现两个高亮行（图 1），分区 + 小标题让「哪个是排序、哪个是分组」自解释；文案进 7 个语言，占位符无。
- **动态项 id 前缀**：`ForEach` 用 id 做 key，分组名与固定项必须不冲突，统一 `group:` 前缀。
- **删除项危险色**：`ShareSettingsView` 原本不是危险色，本次与其它删除动作对齐（行为不变，仅视觉）。
