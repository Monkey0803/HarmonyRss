# HarmonyRss

HarmonyOS（ArkTS）RSS 阅读器。基于 **UI Design Kit（HDS）** 组件与 **ArkUI 状态管理 V2**，
把「结构化正文提取 + Reader 阅读视图 + 离线全文/图片缓存」做成核心体验。

## 功能

- **订阅与阅读**：RSS 2.0 / Atom 1.0 / JSON Feed；分组管理、OPML 导入导出、未读/收藏筛选。
- **自建服务同步（Google Reader API）**：接入 FreshRSS / Tiny Tiny RSS / Miniflux，账密登录后按地址
  合并订阅（保留本地独有源）、增量拉取文章并去重；已读 / 收藏双向同步（本地变更入队批量回写，
  远端状态拉回只改状态列），冲突按 push-first 收敛。密码存入系统 Asset Store，不落明文；
  支持 http 明文地址（需显式开启）与回前台按间隔自动同步（默认关）。设置 → 系统 → 账号与服务。
- **长期历史 + 可撤销清理**：默认永久保留全部历史（不再有 1000 篇上限）；可选 30 / 90 / 365 天或
  「仅保留未读与收藏」。清理前预览影响条数，收藏 / 稍后读 / 有高亮 / 当前打开的文章永不删除，
  被清理文章进入回收站 7 天内可恢复。设置页「存储与保留」展示总占用、按源占用，支持重建检索索引。
- **全局全文检索**：RDB FTS5 索引（标题 / 摘要 / 正文 / 作者），支持 `from:` / `is:` / `after:` /
  `before:` / 引号短语，分页与搜索历史；结果高亮命中片段，点击可定位到正文首个命中。
  中文查询走独立的中文索引（`articles_fts_cjk`：单字 + 相邻二元组，覆盖标题/摘要/正文），
  不依赖设备的 ICU 分词能力；纯英文查询走主索引；两者都不可用才降级为全表 `LIKE`。
  检索路径与耗时、索引条数、中文分词能力可在「存储与保留 → 索引诊断」查看（日志前缀 `CJKIDX`）。
- **单源设置**：每个源可覆盖启用抓取、抓取间隔、全文策略、保留天数、通知、滚动即已读；
  停用源不抓取不通知但保留历史；订阅页与源设置页展示最后成功时间、连续失败次数并可手动重试。
- **标签**：创建 / 重命名 / 删除标签；详情页标题下方展示标签 chips 并可随时增删；
  首页多选可批量打标；标签页多选为 **AND**（只看同时具备全部所选标签的文章），并展示每个标签的文章数。
  标签名会自动归一（去首尾空白、连续空白折叠、≤32 字符、大小写不敏感去重），上限 100 个。
- **智能文件夹**：把常用检索条件（关键词 / `from:` / `is:` / `after:` / `before:` / 引号短语）
  存成「名称 + 查询串」，点一下即用同一条检索链路（含中文索引）执行；搜索页可直接「保存为智能文件夹」。
  支持新建 / 编辑 / 删除 / 上移下移（顺序持久化），空查询与超长查询会被拒绝，上限 50 个。
- **规则引擎**：本地规则按关键词匹配**新入库**的文章（标题 / 摘要 / 正文 / 作者多选，同一规则内多关键词为
  **AND**，大小写不敏感，正文参与匹配前截断到 2 万字符），可限定来源范围（空 = 全部来源）；
  命中后执行已读 / 收藏 / 打标签 / 隐藏，动作只增不减 —— 多条规则命中同一篇时累加，标签与文章去重。
  规则支持启停、优先级上下移（按优先级全量执行）、试运行（预览命中条数，零写入）与累计命中 / 最后命中时间；
  被规则隐藏的文章从主列表与未读数里移除，可在「已隐藏」页找回并取消隐藏。
- **跨源去重**：同一篇文章被多个源收录时只展示一条 —— URL 归一化键（小写 scheme/host、去锚点、
  剔除 `utm_*` / `fbclid` / `gclid` / `ref` / `source` 等追踪参数、忽略末尾斜杠）优先匹配，
  未命中再看「归一化标题 + ±24h 时间窗」；只在**不同源**之间合并（同源重复仍交给既有 id 去重）。
  重复项挂在先入库的主条下且不进列表 / 未读统计，列表显示「N 个来源」，详情页列出全部来源并可分别打开；
  已读 / 收藏 / 隐藏 / 标签等操作对整组生效，主条删除后自动提升组内下一篇。可在设置 → 系统关闭。
- **结构化正文提取**：抓原文 → Readability 式选主容器 → 白名单净化，保留段落 / 标题 / 图片 /
  列表 / 代码 / 引用，而不是把标签抹平成纯文本。
- **Reader 阅读视图**：受控 HTML 文档渲染，排版（字号 / 行距 / 字体 / 栏宽 / 对齐）与
  阅读主题（跟随系统 / 浅色 / 护眼 / 暗色）全部由 App 掌控；网页原文模式作为兜底。
- **离线阅读**：提取后的全文 HTML 落本地库；正文图片内联为 `data:` URI（按魔数嗅探 mime），
  断网也能读；懒加载图（`data-src` / `srcset`）自动恢复。
- **阅读导航**：上一篇 / 下一篇 / 下一条未读；断点续读（记录滚动进度）。
- **正文翻译**：阅读页菜单「翻译全文」、选中正文后「翻译选中段」；逐段与原文对照，可切换「只看译文」。
  目标语言跟随应用语言，源语言自动检测；联网翻译**默认关闭**，开启后才把正文文本发给你选择的服务
  （DeepL 或自建 / 公共 LibreTranslate），API Key 存放在系统资产库。结果按文章 + 目标语言缓存到独立本地库，
  重复打开不再计费，设置页可查看条数并一键清空。
- **分享与导出**：统一分享面板（详情页溢出菜单 / 列表左滑 / 高亮页三处复用），内含系统分享、
  复制链接、复制正文、浏览器打开、稍后读切换；外部目标走免 Key 的 URL Scheme（Pocket / Instapaper /
  Flomo）与 `mailto:` 邮件，未安装或拉起失败时提示并自动复制链接兜底。支持自定义分享模板
  （`{title}` `{url}` `{summary}` `{author}` `{tags}`，可排序 / 编辑，存偏好库），
  以及单篇 / 全部高亮导出 Markdown（复用 `HighlightExport`，保留原有 JSON 导出）。
  所有投递只在用户点击时发生，不发起网络请求。
- **备份与迁移**：把订阅、文章元数据与阅读状态（已读 / 收藏 / 稍后读 / 隐藏 / 进度）、高亮、标签、
  智能文件夹、规则、分享模板与白名单设置导出为版本化 JSON；导入时按各自主键 / 归一化键**合并**
  （已读等状态取并集、进度取最大），不覆盖也不删除现有数据，重复导入保持幂等。
  备份不含正文缓存、远端凭据与设备相关路径；应用私有目录每日自动快照并保留最近 7 份，
  可在「设置 → 系统 → 备份与恢复」中导出 / 导入、恢复或删除快照。
- **通知增强**：新文章通知按源开关与全局关键词过滤（标题 / 摘要，大小写不敏感），
  已读 / 隐藏 / 跨源重复项不打扰；免打扰时段（默认 23:00–08:00）内入队、时段结束后合并补发，
  可选每日摘要（默认关，20:00 后每天一条）。同源通知按 `feed_<id>` 分组，每源最多 3 条、
  单次最多 10 条，超出部分合并为「还有 N 篇」；单条通知可「标记已读 / 收藏」，点击直达文章。
  通知权限状态与申请引导、测试通知在「设置 → 通知设置」。
- **桌面服务卡片**：`entry/src/main/ets/form`。
- **外观**：主题、全局背景图、沉浸光感材质、App logo、防窥保护、智感握姿。

## 目录结构

```
entry/src/main/ets/
  common/      常量、通用组件与工具
  model/       领域模型（@ObservedV2）与设置项
  service/     平台能力与纯逻辑（网络 / 存储 / 解析 / 提取 / 渲染 / 检索 / 保留策略）
  service/remote/  远端服务（GReader 协议 / HTTP / 凭据 / 同步编排）
  viewmodel/   FeedViewModel / RuleViewModel / SettingsViewModel / SearchViewModel / StorageViewModel
  views/       页面与组件（纯展示）
  form/        桌面卡片
entry/src/ohosTest/   仪器化单元测试（hypium）
```

检索与保留：`SearchQueryParser`（语法 → SearchQuery）→ `SearchStore` / `ArticleStore`
（纯英文走主 FTS、含中文走中文二元组索引、异常降级 LIKE）；`CjkTokenizer`（grams / 查询 token 纯函数）、
`SearchPlan`（查询编译 + 子串复核）、`RetentionService`（候选计算 → 移入回收站 → 7 天后清除）。

正文提取管线：`ArticleContentService`（缓存优先 → feed 全文 → 联网抓取）→ `Readability`（选主容器）
→ `HtmlSanitizer`（净化 + URL 绝对化）→ `ImageCache`（图片内联）→ `ReaderDocument`（拼阅读文档）。

统一网络层：`HttpClient`（`service/HttpClient.ets`）集中处理超时、GET/POST 重试（5xx / 429 指数退避，
支持 `Retry-After`）、条件请求（ETag / Last-Modified）、User-Agent、系统代理、全局并发上限与按主机限流；
订阅抓取、正文抓取、图片内联与 Google Reader 远端同步共用，非 2xx 仍由调用方按业务语义处理。

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
