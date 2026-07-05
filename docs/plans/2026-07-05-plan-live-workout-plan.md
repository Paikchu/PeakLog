# Plan Live Workout Plan

- Apple Live Activities 支持 SwiftUI Button；交互按钮用 `LiveActivityIntent` 执行，不打开完整 App。
- Liquid Glass 使用 `glassEffect`、`GlassEffectContainer` 和交互玻璃按钮；所有使用点保留 iOS 26 availability fallback。
- `PeakLogShared/PlanLiveActivityAttributes.swift` 放 ActivityAttributes、snapshot、App Group 共享完成集合。
- `PeakLogLiveActivityExtension` 新增 Widget extension，锁屏/灵动岛只放当前动作、组数进度、完成按钮。
- `PeakLog/Services/LiveActivityManager.swift` 负责 request/update/end Activity，不让 View 直接碰 ActivityKit。
- `TodayWorkoutViewModel` 持有 `PlanLiveWorkoutSession`，合并列表对勾和 Live Activity 按钮完成的 set id；新增 `toggleLiveSet(setId:)` 支持任意组乱序切换完成状态（不再局限于 cursor 指向的“当前组”）。
- `LocalAppDatabase.addPlannedExercise(...)`：today plan 不存在时新建（today 的 `planDate`），存在但为空（Rest）时改写 title/status 并追加第一个动作，否则直接追加到 `exercises`；`TrainingPlanServiceProtocol` 新增同名方法，`LocalTrainingPlanService`/`EmptyTrainingPlanService` 转发。
- `TodayWorkoutViewModel.addPlanExercise(...)` 调用上述 service 方法，返回的 `TrainingPlanDay` 直接替换 `todayPlan`。
- 新增 `AddPlanExerciseSheet`（`PeakLog/Views/Today/AddPlanExerciseSheet.swift`）：Form 输入动作名称、负重类型、目标重量、次数、组数，风格对齐 `DailyRecordSheet`。
- `TodayWorkoutScreen` 右下角加号改为 `Menu`：「添加训练计划」打开 `AddPlanExerciseSheet`，「手动记录」打开原 `DailyRecordSheet`。
- 移除原先内嵌在 Today 页、只展示当前一组的 `planLiveActivityCard`；改为 `.fullScreenCover(isPresented: activeLiveWorkout != nil)` 呈现新的 `TrainingSessionScreen`（`PeakLog/Views/Today/TrainingSessionScreen.swift`），展示全部动作/全部组，每组右侧对勾调用 `toggleLiveSet`，底部「结束并保存」「取消本次训练」。
- 抽出 `PlanProgressBar`（原 `TodayWorkoutScreen` 内 `progressBar` 私有函数）为独立 `View`，并把 `glassPanel`/`glassChip`/`glassActionBackground` 从 `private extension View` 改为 `extension View`，供 `TrainingSessionScreen` 复用同一套玻璃态样式。
- Xcode project 新增 shared group、extension target、entitlements、`NSSupportsLiveActivities` 和 Embed App Extensions。
- 测试覆盖源码入口约束、两组确认落库、Live Activity 外部完成后 Confirm 落库；`today_workout_screen_overlay_layout_test` 更新为断言加号菜单同时暴露手动记录与手动计划语义，且 Start Plan 会呈现 `TrainingSessionScreen`。
