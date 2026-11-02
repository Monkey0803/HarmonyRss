# Tasks: 统一下拉菜单组件（AppMenu）

- [X] T001 `MenuSpec` 纯数据模型（MenuItemSpec / MenuSectionSpec / MenuSpec）
- [X] T002 `AppMenu` 唯一渲染入口（全局 @Builder，卡片 20 / 行高 48 / 高亮块 16）
- [X] T003 `ChoiceMenu`（选项表 → 选择型菜单）+ `ChoiceValueChip`（取值胶囊，@ComponentV2：全局 @Builder 按值传参不刷新，会停在旧文案）
- [X] T004 `radius_menu` token 与 2 条分区文案（7 个语言）
- [X] T005 首页排序菜单拆两分区（排序 / 分组）+ `sortMenuSpec()`
- [X] T006 `MenuSpec` 单元测试并注册进 `List.test.ets`
- [X] T007 迁移 SettingsRows / FeedSettingsView / StorageView 三处选择型选项行
- [X] T008 迁移 RemoteServiceView 三处（服务类型 / 自动同步 / 退出登录）
- [X] T009 迁移 AddFeedPanel 分组菜单（分组选择 + 新建分组两分区）
- [X] T010 迁移 SmartFoldersView / ShareSettingsView / TagsView / ShareSheet 行内动作菜单
- [X] T011 迁移 SubscriptionsView 两处 + ArticleDetailView 动作菜单（图标 / 禁用 / 条件项）
- [X] T012 `radius_menu_item` token 保留（仍被文章页 / 搜索页 / 列表行的非菜单控件引用，迁移后菜单不再使用）
- [X] T013 `devecocli check arkts` / 构建 / CodeLinter / `tools/check-i18n.mjs` / 纯 V2 自查
- [X] T014 真机截图复核（首页排序两分区 / 设置主题 / 订阅源行菜单 / 暗色主题）——文章动作菜单因模拟器浮动操作栏点击不生效，未截图
- [X] T015 ohosTest 全量跑通（426 用例 / 0 失败）并重装主包
