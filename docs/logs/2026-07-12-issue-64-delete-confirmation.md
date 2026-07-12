# Issue #64 修复记录

- 根因已复现：计划动作删除 UI 直接进入 `deletePlanExercise`，已完成组关联的训练记录随数据库关系级联删除；swipe 与 VoiceOver custom action 无确认分支。
- 修复：新增 `PlanExerciseDeletionPolicy`；未完成动作直删，已完成动作弹确认对话框并列出关联记录数量；确认仍进入既有删除路径，取消不 mutation。
- RED：新增 `PlanExerciseDeletionPolicyTests`，在实现前因缺少策略类型编译失败。
- GREEN：待实现后记录策略单测、`TodayExerciseDeleteTests` 与 iOS 26.5 全量 XCTest 结果。
- 风险：确认对话框依赖当前页面中的计划快照；ViewModel 删除失败时通过已有 refresh 恢复 UI。
