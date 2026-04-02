# 2026-04-02 架构/流程/接口文档补充

## 本次目标

为 PeakLog 补充可维护的项目文档，便于后续升级、排障和交接。

## 已完成内容

- 新增 `docs/architecture/README.md`（文档导航）
- 新增 `docs/architecture/system-architecture.md`（系统架构）
- 新增 `docs/architecture/business-flow.md`（业务流程）
- 新增 `docs/architecture/api-reference.md`（接口文档）

## 覆盖范围

- iOS 分层结构（View / ViewModel / Service / Model）
- Supabase Edge Functions（`chat-send-message`、`ai-workout-action`）
- 训练记录与计划核心数据模型
- SSE 事件协议与关键 content block 契约
- 关键业务时序与异常降级路径

## 维护建议

- 每次接口字段或 content block 结构变更时，必须同步更新 `api-reference.md`
- 每次流程调整时，先更新 `business-flow.md`，再改实现
- 跨模块改动前，先更新 `system-architecture.md` 中的模块职责和边界
