# 移除 ai-workout-action

- 已删除本地 Supabase `ai-workout-action` Edge Function。
- 已删除只服务该函数的 `_shared` agent/schema/pr-summary/env/deps 模块。
- 已删除后端 agent/schema/helper 测试。
- 已删除 iOS 侧 `WorkoutAIActionService` 空壳和 Today ViewModel 的 `quickActions` 状态。
- 已更新 README 与架构文档：当前版本不保留 Edge Function API，训练记录和计划调整走显式 UI 与本地 service。
- 远端 Supabase 项目需要同步删除 `ai-workout-action` 函数。
