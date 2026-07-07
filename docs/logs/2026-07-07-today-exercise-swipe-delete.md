# 2026-07-07 今日动作滑动删除

## 需求

今日页的计划动作无法删除。为每个动作组件（计划动作卡片 + 记录动作卡片）增加由右向左滑动删除，已完成的动作同样支持。需求文档：`docs/requirements/2026-07-07-today-exercise-swipe-delete.md`。

## 实现

### UI

- 新增 `PeakLog/Views/Today/SwipeToDeleteRow.swift`：通用左滑删除容器（iOS 原生风格）。卡片区不在 List 内无法用系统 `swipeActions`，用 `DragGesture(minimumDistance: 24)` 实现，只跟随横向手势（纵向仍交给 ScrollView）；左滑露出 76pt 红色删除按钮，**只有点击按钮才删除**，滑动过头只有橡皮筋衰减回弹（1/4 阻尼，最多 28pt），不做全滑直接删除；按钮展开期间点击卡片先收起，避免误触内部编辑控件。带触觉反馈与 VoiceOver `accessibilityAction`。
- `TodayWorkoutScreen.swift`：
  - `TodayPlanExercisesSection` 新增 `onDeleteExercise` 回调，浏览模式下 `TodayPlannedExerciseCard` 包进 `SwipeToDeleteRow`（专注模式与重排模式不启用滑动删除）；列表用 `.animation(flowAnimation, value: exercises.map(\.id))` 做删除收拢动画。
  - `TodayRecordsSection` 透传 `onDeleteExercise` 到 `WorkoutRecordCard`。
- `WorkoutRecordCard.swift`：新增可选 `onDeleteExercise`，非 nil 时每个 `ExerciseCardView` 包进 `SwipeToDeleteRow`。

### 状态层（TodayWorkoutViewModel）

- `deletePlanExercise(planExerciseId:)`：乐观移除 + 重写 `orderIndex` → 调服务删除 → `refreshTodayRecordOnly()` 同步记录区（级联删除后）；失败回滚走 `refresh()`。
- `removeExerciseFromLiveSession(_:)`：训练进行中删除计划动作时，从 live session 剔除该动作（清 completedSetIds/skipped/manualFocus），指针重新流转；动作删空则 `cancelPlanLiveWorkout()`。
- `deleteLoggedExercise(exerciseId:)`：乐观移除记录动作，记录删空置 nil。

### 服务层 / 数据层

- `TrainingPlanServiceProtocol.deletePlannedExercise(planExerciseId:)`、`WorkoutServiceProtocol.deleteExercise(sessionId:exerciseId:)` 新协议方法（Local 与 Empty 实现均已补齐）。
- `LocalAppDatabase.deletePlannedExercise`：删除计划动作并重写 `orderIndex`；**级联删除**已完成组通过 `linkedExerciseSetId` 落库的记录组（`removeLoggedSets(withIds:)`），清空的记录动作与 session 一并移除。
- `LocalAppDatabase.deleteExercise`：删除记录动作（今日记录是多 session 合并展示，传入 sessionId 找不到时回退全量查找）；session 清空则移除；指向被删记录组的计划组回退为未完成（`clearPlanCompletionLinks(to:)`）。

### 测试

- 新增 `PeakLogTests/TodayExerciseDeleteTests.swift`（3 个用例）：已完成计划动作删除级联记录、记录动作删除连带空 session、训练进行中删除动作对 live session 的剪枝与删空取消。
- 同步补齐协议新方法的 mock stub：`PeakLogTests/TodayWorkoutLiveSessionTests.swift`、`PeakLogTests/TodayWorkoutFocusFlowTests.swift`、`tests/today_running_coexistence_test.swift`、`tests/history_running_view_model_test.swift`（并顺手补上 coexistence 缺失的 `reorderPlannedExercises` stub）。

## 决策记录

- 「删除对应的记录或者计划」取双向一致语义：删计划动作 → 连带删它产生的记录；删记录动作 → 关联计划组回退未完成。避免任一方向留下孤儿数据。
- 删除必须点按钮（用户明确要求）：滑动只负责展开/收起，不做系统 Mail 那种全滑直删，防误删。展开后点按钮即删，不再叠加确认框。

## 验证

- `xcodebuild -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build` 通过。
- `xcodebuild test`（同 destination）21 个用例全部通过（含本需求 3 个新用例，与并行开发的动作重排改动共存）。
- `swift tests/today_workout_screen_overlay_layout_test.swift`、`swiftc -parse-as-library tests/service_layer_mock_boundary_test.swift` 通过。
- 未完成验证项：模拟器真实手势链路（左滑露按钮/全滑删除/滚动不冲突）建议在 Xcode 环境手动过一遍。
