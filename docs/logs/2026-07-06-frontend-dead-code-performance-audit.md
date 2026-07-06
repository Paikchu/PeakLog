# 前端废弃代码与 SwiftUI 性能审查

## 废弃代码

- 已删除 `PeakLog/Views/History/SessionDetailRow.swift`：历史页当前只渲染 `HistoryCompletedTrainingSection`，`SessionDetailRow` 没有运行入口。
- 已删除 `ExerciseCardPanGesture`、`ExerciseCardSwipeGestureCoordinator` 和对应源码测试：Today 的自由训练记录页传入的是空删除回调，滑动删除按钮只展示、不改变数据。
- 已移除 `WorkoutRecordCard` / `ExerciseCardView` 的 `messageId`、`onDeleteExercise` 参数：这是聊天消息卡片时代的遗留上下文，当前记录卡不依赖 message identity。
- 已移除 `Color.accentRed`、`Font.deleteLabel`：只服务旧滑动删除按钮，删除按钮移除后无引用。
- 已确认 `WorkoutAIActionService.swift` 和 `ai-workout-action` 后端删除没有前端引用回流；这批删除是工作区既有改动，本次没有恢复。
- 未删除 `chat.exercise.*` 和 `chatBody*`：命名过时，但 Today/History 仍在用；应改名迁移，不应直接删。
- 未删除 `auth.*`、`chat.input.*`、`conversation.*`、`error.speech.*` 本地化 key：当前无入口，建议单独做资源瘦身，避免 `.xcstrings` 大面积格式 churn。

## 可继续优化

- `TodayWorkoutScreen` 直接观察完整 `TodayWorkoutViewModel`，任何 `@Published` 变化都会重算大视图；拆出 header、plan list、record list、focus session 子状态，降低 invalidation fan-out。
- `CalendarGridView` 在 body 相关路径反复创建 `DateFormatter`；weekday、month title、day number 应缓存 formatter 或改用 `Date.FormatStyle`。
- `HistoryViewModel.loadCalendar()` 同时调用 strength/running active day，但 `LocalAppDatabase.activeDaysInMonth` 已合并两类记录；保留一个入口，减少重复查询和状态更新。
- `LocalAppDatabase` 构建时出现 Swift 6 并发隔离警告；`LocalAppState`、Live Activity shared model、formatter helper 应从 MainActor 依赖中拆出来。
- 已处理：`WorkoutServiceProtocol.updateExerciseName/deleteExercise` 没有前端入口，已收缩到当前真实工作流。
- README 仍描述邮箱登录、Realtime、Supabase Auth、旧聊天架构；代码已经本地化，应重写 README 当前架构段。
- `MockProfileService`、`MockWorkoutService`、`MockTrainingPlanService` 当前无生产调用；更适合移动到测试/Preview 支撑层，避免服务层同时承担运行与假数据职责。

## 验证

- XcodeBuildMCP build：`PeakLog` / iOS 26.5 `iPhone 17 Pro Max` / `CODE_SIGNING_ALLOWED=NO` 通过。
- XcodeBuildMCP test：18 个 XCTest 通过，0 失败。
- XcodeBuildMCP build-run：App 启动成功，bundle `com.max.PeakLog`。
- SwiftUI 性能结论为代码审查结论；未采集 Instruments trace，无法给出 CPU、hitch、memory 的 before/after 数值。

## 参考

- Apple: [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
- Apple WWDC25: [Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/)
- Apple WWDC23: [Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)
