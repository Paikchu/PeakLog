# Issue #64 删除已完成计划动作确认计划

- 根因：`SwipeToDeleteRow` 的点击删除与 VoiceOver `accessibilityAction` 共用 `onDelete`，而页面回调直接调用 `TodayWorkoutViewModel.deletePlanExercise`；该方法先乐观移除计划，再由数据库级联删除已完成组关联的训练记录。
- 范围：只拦截包含已完成组的计划动作；未完成动作保持即时删除。取消确认对话框不产生 mutation，确认按钮调用同一个 ViewModel 删除入口。
- 影响提示：对话框展示动作名称、关联已完成组数量和不可撤销说明。
- 失败处理：沿用 ViewModel 的删除失败刷新路径，恢复计划、进行中 session 和记录区 UI。
- 测试：策略单测覆盖未完成即时删除与已完成确认；既有 `TodayExerciseDeleteTests` 覆盖确认后的级联行为；在 iOS 26.5 iPhone 17 Pro Max Simulator 运行全量 XCTest。
- 不涉及：数据库 schema、migration、RLS、Supabase 部署或 rollback。
