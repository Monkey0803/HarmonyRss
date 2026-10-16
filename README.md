# HarmonyRss

HarmonyOS（ArkTS）RSS 阅读器。基于 **UI Design Kit（HDS）** 组件与 **ArkUI 状态管理 V2**，
把「结构化正文提取 + Reader 阅读视图 + 离线全文/图片缓存」做成核心体验。

## 功能

- **订阅与阅读**：RSS 2.0 / Atom 1.0 / JSON Feed；分组管理、OPML 导入导出、搜索、未读/收藏筛选。
- **结构化正文提取**：抓原文 → Readability 式选主容器 → 白名单净化，保留段落 / 标题 / 图片 /
  列表 / 代码 / 引用，而不是把标签抹平成纯文本。
- **Reader 阅读视图**：受控 HTML 文档渲染，排版（字号 / 行距 / 字体 / 栏宽 / 对齐）与
  阅读主题（跟随系统 / 浅色 / 护眼 / 暗色）全部由 App 掌控；网页原文模式作为兜底。
- **离线阅读**：提取后的全文 HTML 落本地库；正文图片内联为 `data:` URI（按魔数嗅探 mime），
  断网也能读；懒加载图（`data-src` / `srcset`）自动恢复。
- **阅读导航**：上一篇 / 下一篇 / 下一条未读；断点续读（记录滚动进度）。
- **桌面服务卡片**：`entry/src/main/ets/form`。
- **外观**：主题、全局背景图、沉浸光感材质、App logo、防窥保护、智感握姿。

## 目录结构

```
entry/src/main/ets/
  common/      常量、通用组件与工具
  model/       领域模型（@ObservedV2）与设置项
  service/     平台能力与纯逻辑（网络 / 存储 / 解析 / 提取 / 渲染）
  viewmodel/   FeedViewModel / SettingsViewModel
  views/       页面与组件（纯展示）
  form/        桌面卡片
entry/src/ohosTest/   仪器化单元测试（hypium）
```

正文提取管线：`ArticleContentService`（缓存优先 → feed 全文 → 联网抓取）→ `Readability`（选主容器）
→ `HtmlSanitizer`（净化 + URL 绝对化）→ `ImageCache`（图片内联）→ `ReaderDocument`（拼阅读文档）。

## 硬性约束：只支持状态管理 V2

允许：`@ComponentV2`、`@ObservedV2`+`@Trace`、`@Local`、`@Param`、`@Once`、`@Event`、
`@Monitor`、`@Computed`、`@Provider`/`@Consumer`。

禁止：`@Component`、`@State`、`@Prop`、`@Link`、`@Provide`、`@Consume`、`@Observed`、
`@ObjectLink`、`@Watch`、`@StorageLink`、`AppStorage`、`LocalStorage`、`PersistentStorage`、
以及 V1 组件 `HdsListItem`。详见 [AGENTS.md](AGENTS.md)。

## 构建与运行

前置：DevEco Studio（含 SDK 与自带 JBR）。

```sh
export DEVECO_SDK_HOME="<DevEco SDK 目录>"
export JAVA_HOME="<DevEco 自带 JBR/Contents/Home>"

# 构建
hvigorw --mode project -p product=default assembleApp -p buildMode=debug

# 单测（设备上运行，见 AGENTS.md「单元测试」）
scripts/harmony.sh test
```

### 已知环境限制：工程路径不能含非 ASCII

hvigor CLI 会拒绝含非 ASCII 的工程路径（报 `00306003 Invalid project path`）。若仓库目录名含中文
（如本仓库的 `解析`），请：

- 把工程移/软链到纯 ASCII 路径后再构建，或直接使用 DevEco Studio 构建；
- 或使用 `scripts/harmony.sh`：它会把工程同步到 ASCII 临时目录（默认 `/tmp/harmonyrss-build`，
  可用 `HARMONY_ASCII_DIR` 覆盖）再执行构建 / 测试。

```sh
scripts/harmony.sh build   # 同步到 ASCII 目录并构建 App
scripts/harmony.sh test    # 同步、构建测试 HAP、安装并在设备上跑单测
scripts/harmony.sh clean   # 清理 ASCII 临时目录
```
