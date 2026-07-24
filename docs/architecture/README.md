# PeakLog 架构文档导航

本目录用于维护 PeakLog 的核心技术文档，帮助后续迭代、排障、交接和重构。

## 文档清单

- `system-architecture.md`  
  系统架构文档，包含分层结构、模块职责、数据存储与关键设计决策。

- `business-flow.md`  
  业务功能流程文档，覆盖核心用户路径与主要时序（聊天记录、今日计划、历史回顾、个人目标）。

- `api-reference.md`  
  接口文档，包含 iOS 侧调用的 Supabase Edge Functions、SSE 事件协议、关键数据结构与错误语义。

- `adr-001-llm-weekly-plan-generation.md`  
  架构决策记录：LLM 驱动的每周训练计划自动生成（周粒度生成、LLM 决策 + 确定性薄层、编辑事件流、计划溯源、周中动态重排）。Phase 0 前置方案见 `../plans/2026-07-07-phase0-auth-sync-plan.md`；Phase 1（结构化目标 GoalSpec、编辑事件流、生成溯源基建）见 `../plans/2026-07-08-phase1-edit-events-goalspec-plan.md`；Phase 2（`generate-weekly-plan` Edge Function 主链路、pg_cron 调度、C21 硬约束）见 `../plans/2026-07-08-phase2-weekly-generation-plan.md` 与 `../logs/2026-07-08-phase2-weekly-generation.md`；Phase 3（周中动态重排：一键信号 + 行为推断、`replan_plan_days` RPC、C31 硬约束、revision 乐观锁）见 `../plans/2026-07-08-phase3-midweek-replan-plan.md` 与 `../logs/2026-07-08-phase3-midweek-replan.md`。

- `ai-plan-generation.md`  
  AI 计划生成子系统的架构与设计（ADR-001 的实现细节配套），从三个视角展开并配 Mermaid 图：**AI 决策如何做出**（三层分工、weekly 时序、replan 决策边界）、**记忆系统如何构成**（意图/情节/行为/语义/程序性/溯源六类记忆与学习闭环）、**如何保证生成动作的可靠性**（Validator 校验与钳制、repair loop 与 fallback、并发乐观锁、时区正确性、dry_run 迭代）。

## 阅读建议

1. 新成员入项：先读 `system-architecture.md`
2. 理解功能闭环：再读 `business-flow.md`
3. 联调/排障：重点看 `api-reference.md`
4. 深入 AI 计划：先读 `adr-001-llm-weekly-plan-generation.md`（为什么），再读 `ai-plan-generation.md`（怎么做）

## 维护约定

- 功能行为或数据结构变化时，同步更新对应文档。
- 接口字段变更时，必须同时更新 `api-reference.md`。
- 新增跨模块能力时，先补充架构与流程图，再进入开发实现。
