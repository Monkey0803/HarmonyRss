# Implementation Plan: 多语言扩展（繁體中文首批）

## Source Changes

- `SettingsConstants.AppLanguage` 新增 `ZH_TW = 'zhTW'`。
- `SettingsOptions.LANGUAGE_OPTIONS` 新增「繁體中文」。
- `LocaleController`：`ZH_TW` → `setAppPreferredLanguage('zh-Hant')`。
- 新增 `entry/src/main/resources/zh_Hant/element/string.json`（1011 条，OpenCC s2twp 生成）。
- `README` / `TODO` 更新语言能力。

## Decisions

- 使用 script 限定词 `zh_Hant` 而不是 `zh_TW`，同时覆盖台湾 / 香港等繁体环境。
- 全量转换而不是只翻菜单，避免界面中英 / 简繁混排。
- 机器转换后保留英文专有名词与占位符；后续补充日 / 德 / 法 / 西时沿用同一套目录结构。
