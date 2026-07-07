# 今日计划动作顺序调整 — 技术方案

需求文档：`docs/requirements/2026-07-06-plan-exercise-reorder.md`

## 改动总览

| 文件 | 改动 |
|---|---|
| `PeakLog/Models/TrainingPlanModels.swift` | `TrainingPlanExercise.orderIndex` 由 `let` 改 `var`；新增纯函数 `TrainingPlanDay.reordered(byExerciseIds:)`（校验 + 重排 + 重编号，swiftc 可测） |
| `PeakLog/Services/TrainingPlanService.swift` | 协议新增 `reorderPlannedExercises(orderedExerciseIds:) async throws -> TrainingPlanDay`；Local/Empty 两个实现照抄现有转发模式 |
| `PeakLog/Services/LocalAppDatabase.swift` | 新增 `reorderPlannedExercises(orderedExerciseIds:) throws -> TrainingPlanDay`：定位今日 day → 调用模型纯函数 → 非法排列抛 `invalidExerciseOrder` → persist |
| `PeakLog/ViewModels/TodayWorkoutViewModel.swift` | 新增 `reorderTodayPlanExercises(orderedExerciseIds:) async`：乐观更新本地顺序 → 落库 → 失败回滚（`refresh()`，与现有方法一致）；训练进行中（`activeLiveWorkout != nil`）时该方法不生效，UI 层已阻止进入重排模式，此处只做兜底 guard |
| `PeakLog/Views/Today/TodayWorkoutScreen.swift` | `TodayPlanExercisesSection` 增加重排模式：长按卡片进入，紧凑行 + 自定义 `DragGesture` 拖拽排序，完成按钮/点击空白退出 |
| `PeakLog/Localizable.xcstrings` | 新增重排模式相关文案（标题/完成按钮/训练中提示/无障碍上移下移） |
| `tests/plan_exercise_reorder_test.swift` | **新增**：纯函数重排逻辑测试 |

## 数据模型

```swift
extension TrainingPlanDay {
    /// 按 orderedExerciseIds 重排 exercises 并重写 orderIndex(0..<count)。
    /// orderedExerciseIds 必须是当前 exercises id 集合的一个排列，否则返回 nil。
    func reordered(byExerciseIds orderedExerciseIds: [String]) -> TrainingPlanDay? {
        guard orderedExerciseIds.count == exercises.count,
              Set(orderedExerciseIds) == Set(exercises.map(\.id)) else { return nil }
        let byId = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        var newExercises: [TrainingPlanExercise] = []
        for (index, id) in orderedExerciseIds.enumerated() {
            guard var exercise = byId[id] else { return nil }
            exercise.orderIndex = index
            newExercises.append(exercise)
        }
        var day = self
        day.exercises = newExercises
        return day
    }
}
```

`orderIndex` 改 `var` 是唯一的模型改动；`TrainingPlanExercise` 其余字段不变。

## Service / Database

```swift
// TrainingPlanServiceProtocol
func reorderPlannedExercises(orderedExerciseIds: [String]) async throws -> TrainingPlanDay
```

`LocalAppDatabase`：

```swift
func reorderPlannedExercises(orderedExerciseIds: [String]) throws -> TrainingPlanDay {
    let todayDateString = Self.planDateString(from: Date())
    guard let dayIndex = state.activePlan.days.firstIndex(where: { $0.planDate == todayDateString }) else {
        throw LocalAppDatabaseError.planExerciseNotFound
    }
    guard let reorderedDay = state.activePlan.days[dayIndex].reordered(byExerciseIds: orderedExerciseIds) else {
        throw LocalAppDatabaseError.invalidExerciseOrder
    }
    state.activePlan.days[dayIndex] = reorderedDay
    try persist()
    return reorderedDay
}
```

新增错误 case `invalidExerciseOrder`（理论上只会在极端并发下触发——例如重排提交前另一个操作删除了某个动作）。

## ViewModel

```swift
func reorderTodayPlanExercises(orderedExerciseIds: [String]) async {
    guard activeLiveWorkout == nil, let plan = todayPlan else { return }
    let previous = plan.exercises
    let optimistic = orderedExerciseIds.compactMap { id in previous.first { $0.id == id } }
    guard optimistic.count == previous.count else { return }
    todayPlan?.exercises = optimistic

    do {
        let updated = try await trainingPlanService.reorderPlannedExercises(orderedExerciseIds: orderedExerciseIds)
        todayPlan = updated
    } catch {
        errorMessage = error.localizedDescription
        await refresh()
    }
}
```

沿用现有方法的"乐观更新 + 失败时 `errorMessage` + `refresh()`"模式（与 `completePlannedSet`/`updatePlannedSet` 一致），不额外发明回滚机制。

## UI：重排模式

`TodayPlanExercisesSection` 新增 `@State private var isReordering = false` 与 `@State private var draftOrder: [TrainingPlanExercise]`（进入时从 `state.plan.exercises` 快照）。

- **进入**：非专注模式下卡片加 `.onLongPressGesture(minimumDuration: 0.4)`，触发时 `withAnimation` 切到 `isReordering = true`，同时 `UIImpactFeedbackGenerator(.medium)`。专注模式（`isFocusMode`）不挂该手势——训练中天然无法进入。
- **紧凑行**：`ReorderableExerciseRow`——`RoundedRectangle` 色条 + 动作名 + `"\(completedSets)/\(totalSets)"` 组数徽章 + 右侧 `Image(systemName: "line.3.horizontal")` 拖拽把手，固定高度（52pt）。
- **拖拽手势**：把手上挂 `DragGesture(minimumDistance: 0)`：
  - `onChanged`：累加垂直位移，`let targetIndex = clamp(draggedIndex + Int(round(translation / rowHeight)))`；当 `targetIndex` 变化时 `draftOrder.move(fromOffsets:toOffset:)` + `withAnimation(.spring)` + 轻触觉反馈；被拖行叠加剩余小数位移做跟手位移，其余行仅响应 index 变化做位置动画（不跟手）。
  - `onEnded`：清除跟手偏移，若顺序确有变化则 `Task { await viewModel.reorderTodayPlanExercises(orderedExerciseIds: draftOrder.map(\.id)) }`。
  - 重排模式下 `ScrollView` 外层加 `.scrollDisabled(true)`（通过 environment 传下去，或重排态下整段紧凑列表用固定高度 `VStack` 替代滚动区域——一屏放不下时用户仍可先退出模式滚动，v1 接受此限制）。
- **退出**：顶部/底部出现"完成"按钮（复用现有 `glassChip` 样式），或点击列表外空白区域退出；退出时 `isReordering = false`，卡片以 `.opacity`/`.scale` 过渡展开回原样。
- **无障碍**：`ReorderableExerciseRow` 加 `.accessibilityAction(named: "上移") { moveUp() }` 与 `.accessibilityAction(named: "下移") { moveDown() }`，效果与拖拽等价，直接调用同一个 `draftOrder.move` + 提交逻辑，不依赖手势。

## 测试（tests/plan_exercise_reorder_test.swift）

1. 正常重排：3 个动作换到 `[c, a, b]`，输出 `orderIndex` 为 `0,1,2` 且顺序正确。
2. 非法排列（id 集合不匹配/数量不符/重复 id）→ 返回 `nil`。
3. 单动作/两动作边界情况。
4. 重排不改变每个动作内部的 `sets`/`notes`/`aiSuggestion` 等字段（仅顺序和 `orderIndex` 变化）。

编译源码清单沿用现有约定，追加无新文件（`TrainingPlanModels.swift`、`LocalAppDatabase.swift`、`TrainingPlanService.swift` 均已在清单内）：

```
PeakLog/Models/{ExerciseLibraryModels,TrainingPlanModels,WorkoutModels,UserProfile,PlanExerciseFormModel,DailyRecordFormModel,HistoryCompletedModels,WorkoutHistoryAggregator}.swift
PeakLog/Services/{LocalAppDatabase,ExerciseLibraryService,ProfileService,WorkoutService,TrainingPlanService}.swift
PeakLog/Localization/AppLanguage.swift
PeakLog/Support/WorkoutDateFormatter.swift
```

## 验收
- 新测试通过 + 受影响的既有 swiftc 测试（`plan_exercise_draft_builder_test` 等涉及 `TrainingPlanModels`/`LocalAppDatabase` 的）重跑通过；`xcodebuild test` 通过。
- 模拟器手动验证：长按进入重排、拖拽换序、退出后卡片展开顺序正确、杀进程重开顺序保留、训练进行中长按无反应。
