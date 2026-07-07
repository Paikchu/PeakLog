# 今日计划动作顺序调整实现记录

需求：`docs/requirements/2026-07-06-plan-exercise-reorder.md`
方案：`docs/plans/2026-07-06-plan-exercise-reorder-plan.md`

## 本次实现

- `TrainingPlanModels.swift`：`TrainingPlanExercise.orderIndex` 由 `let` 改 `var`；新增 `TrainingPlanDay.reordered(byExerciseIds:)` 纯函数——校验 `orderedExerciseIds` 是当前 exercises id 集合的排列，重排并重写 `orderIndex(0..<count)`，非法排列返回 `nil`。
- `TrainingPlanServiceProtocol` 新增 `reorderPlannedExercises(orderedExerciseIds:)`，`LocalTrainingPlanService`/`EmptyTrainingPlanService` 照抄现有转发模式；`LocalAppDatabase` 新增同名方法（定位今日 day → 调用模型纯函数 → 非法排列抛新增的 `invalidExerciseOrder`）。
- `TodayWorkoutViewModel` 新增 `reorderTodayPlanExercises(orderedExerciseIds:)`：训练进行中（`activeLiveWorkout != nil`）时不生效；乐观更新本地顺序 → 落库 → 失败时 `errorMessage` + `refresh()`，与既有方法风格一致。
- `TodayWorkoutScreen.swift`：
  - 长按 `TodayPlannedExerciseCard` 的动作名/色条区域（非整卡，避免与组行的 RPE 长按菜单冲突）进入重排模式。
  - 新增 `ReorderableExerciseList`/`ReorderableExerciseRow`：等高紧凑行 + 自定义 `DragGesture`（累计位移按行高换算目标下标，`items.move` + 弹簧动画 + 触觉反馈），松手一次性提交新顺序；顶部「完成」按钮退出（复用 `common.done`）。
  - 无障碍：每行加 `accessibilityAction`（上移/下移），效果等价拖拽。
  - 重排模式下 `ScrollView` 加 `.scrollDisabled`；进入专注模式时强制退出重排。
- 新增本地化键 `today.plan.reorder.{title,sets_badge,move_up,move_down}`（en/zh-Hans），复用既有 `common.done`。

## 验证中发现并修复的问题

1. `@State private var draftOrder` 写在同时声明了嵌套 `struct State` 的 `TodayPlanExercisesSection` 内，`@State` 被嵌套类型遮蔽导致 "struct 'State' cannot be used as an attribute" 编译错误 → 改用完全限定的 `@SwiftUI.State`。
2. 实现期间另有并行提交（`7f27410`/`1cd5076`）落地了动作选择器推荐与「今日添加行」重构，且开发过程中还并行接入了滑动删除计划动作/记录动作（`SwipeToDeleteRow`、`deletePlannedExercise`、`deleteExercise`）——协议扩展后 `PeakLogTests` 里的两个 mock（`FocusFlowTrainingPlanService`/`LiveSessionTrainingPlanService`）缺少新增方法导致协议不符 → 补上 `reorderPlannedExercises` 桩实现（`deletePlannedExercise`/`deleteExercise` 桩已由该并行改动补齐）。

## 测试

新增 `tests/plan_exercise_reorder_test.swift`（swiftc 编译型），源码清单沿用既有约定并追加 `ExerciseRecommendationEngine.swift`：

```
PeakLog/Models/{ExerciseLibraryModels,TrainingPlanModels,WorkoutModels,UserProfile,PlanExerciseFormModel,DailyRecordFormModel,HistoryCompletedModels,WorkoutHistoryAggregator}.swift
PeakLog/Services/{LocalAppDatabase,ExerciseLibraryService,ExerciseRecommendationEngine,ProfileService,WorkoutService,TrainingPlanService}.swift
PeakLog/Localization/AppLanguage.swift
PeakLog/Support/WorkoutDateFormatter.swift
```

覆盖：正常重排+`orderIndex`重编号、id 集合不匹配、数量不符（过多/过少）、重复 id、字段与 sets 保持不变、单动作边界。

结果：新测试 + 受影响的既有 swiftc 测试（`plan_exercise_draft_builder_test`、`daily_record_multi_exercise_draft_test`、`local_state_decode_compat_test`、`exercise_library_search_test`、`exercise_picker_recent_test`、`exercise_recommendation_test`）全部通过；`xcodebuild build`/`xcodebuild test`（iPhone 17 Pro Max 模拟器）通过。模拟器手动交互验证因用户拒绝了本次 computer-use 对 Simulator 的访问授权而未执行，功能是否符合预期需要用户自行在模拟器中确认。
