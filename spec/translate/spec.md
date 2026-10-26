# Feature Specification: 正文翻译

**Created**: 2026-10-26
**Status**: Implemented
**Input**: `TODO.md` P1-4。

## Overview

在阅读页提供整篇 / 选段翻译，逐段与原文对照，并支持只看译文。
当前 SDK 没有可用的系统级文本翻译 API，因此实现为「可配置的第三方服务」（DeepL / LibreTranslate 兼容接口）；
接口保留「系统能力不可用 → 第三方」的降级语义。默认关闭联网翻译，API Key 存系统资产库，
结果按文章 + 目标语言缓存到独立本地库。

## Requirements

- **FR-001**: 阅读页菜单提供「翻译全文」；选中正文后可「翻译选中段」。
- **FR-002**: 逐段对照展示；支持切换「只看译文」。
- **FR-003**: 语言自动检测；目标语言跟随应用语言（跟随系统时中文 → zh、其余 → en）。
- **FR-004**: 默认关闭联网翻译；关闭时只提示，不发起请求、不影响阅读。
- **FR-005**: 支持 DeepL（必填 Key）与 LibreTranslate 兼容端点（可自定义服务地址）。
- **FR-006**: API Key 只存 Asset Store，不写入 preferences / 数据库 / 日志 / 备份。
- **FR-007**: 翻译结果按 (articleId, targetLang) 缓存，重新打开不再计费；设置页可查看条数并清空。
- **FR-008**: 网络 / 鉴权 / 限流 / 服务端 / 解析错误给明确可操作提示；配置类错误提供「打开翻译设置」。
- **FR-009**: 正文最多翻译前 20,000 字符，超出时界面提示；单次请求按段落批次拆分。
- **FR-010**: 新增界面文案中英文成对。

## Acceptance

- 关闭开关时点击翻译 → 面板提示未开启并可跳到设置，不崩溃、不联网。
- 配置 DeepL Key 后翻译英文文章 → 逐段中文对照；再次打开命中缓存。
- 断网 / Key 失效 / 429 分别有明确提示，阅读与其他功能不受影响。
- 清空缓存后条数归零。

## Key Entities

- `TranslationParagraph`：原文 + 译文。
- `TranslationResult`：段落、源 / 目标语言、服务、是否缓存、是否截断。
- 缓存表：`translations(article_id, target_lang, source_lang, provider, payload, updated_at)`。
