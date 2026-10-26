# Tasks: 远端服务适配层 + Feedbin

- [X] T001 `RemoteBackend` 接口与会话 / 文章页 / 状态变更 / 回写结果模型
- [X] T002 GReaderBackend：认证、订阅、continuation + 时间戳游标、edit-tag 回写
- [X] T003 FeedbinModels：订阅 / 条目 / id 解析、地址归一、ISO 游标
- [X] T004 FeedbinBackend：Basic Auth、订阅、条目分页（since）、未读 / 收藏、批量回写
- [X] T005 RemoteSyncService 改为按 serviceType 选择后端
- [X] T006 文章增量改用不透明游标 + Backend.betterCursor
- [X] T007 状态回写改用中立变更 + 批量结果
- [X] T008 切换服务 / 地址清理旧映射、outbox 与游标
- [X] T009 账号页服务类型选择 + Feedbin 表单文案
- [X] T010 中英文案 / README / TODO / PRIVACY
- [X] T011 单测（FeedbinModels / 游标语义）与聚合
- [X] T012 `arkts_check` / 纯 V2 自查 / `build_project` / ohosTest
