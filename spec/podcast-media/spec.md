# Feature Specification: 播客 / 视频 enclosure

**Created**: 2026-10-26
**Status**: Implemented
**Input**: `TODO.md` P1-5。

## Overview

解析 feed 媒体附件（RSS `enclosure` / Atom `link rel="enclosure"` / Media RSS `media:content` /
JSON Feed `attachments`），在列表与详情展示媒体标识；播客支持后台播放、锁屏控制、倍速、±15s、
进度记忆与队列；视频交给系统播放器（浏览器兜底）；与正文朗读（TTS）互斥。

## Requirements

- **FR-001**: 模型提供 `Enclosure(url / type / length / duration)` 与音频 / 视频判定。
- **FR-002**: RSS / Atom / Media RSS / JSON Feed 四种来源都能解析附件与时长。
- **FR-003**: 附件持久化到文章表（JSON 列），升级老库自动补列。
- **FR-004**: 列表显示播客 / 视频图标，播客带时长。
- **FR-005**: 详情页标签条显示媒体 chip（播客带时长），点击可直接播放 / 打开。
- **FR-006**: 音频播放器：播放 / 暂停、±15s、0.75–2.0 倍速、上一首 / 下一首、停止。
- **FR-007**: 队列：当前来源未听 / 全部未听；播完自动下一首。
- **FR-008**: 播放进度按文章写入本地库，重新打开从上次位置继续；播完视为已听。
- **FR-009**: 后台播放：AUDIO_PLAYBACK 长时任务 + AVSession 锁屏 / 媒体中心控制。
- **FR-010**: 视频：调用系统播放器，失败时退回浏览器。
- **FR-011**: 与 TTS 互斥：开始音频前停朗读；开始朗读前暂停音频。
- **FR-012**: 权限：新增 `KEEP_BACKGROUND_RUNNING` 与 `backgroundModes: ["audioPlayback"]`，同步权限审计文档。

## Acceptance

- 订阅带 enclosure 的播客源后，列表出现耳机图标与时长；详情出现播客 chip。
- 播放后锁屏可暂停 / 继续 / 切歌 / 调整进度；退回前台进度一致。
- 退出详情再进入仍可从上次位置继续；「全部未听」不包含已播完条目。
- 视频点击能拉起系统播放器或浏览器。
- 播放音频时启动朗读不会同时出声。
