import Foundation

// 未来日编辑器（Phase A.5）契约：与今日计划共用同一套卡片组件，但
// 隐藏完成勾选与有氧开始入口；休息日与训练日都保留添加动作行；
// 只读的 PlanDayPreviewSection 已被交互编辑器取代。
let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let futureSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/Views/Training/FutureDayContent.swift"),
    encoding: .utf8
)
let componentsSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/Views/Today/PlanExerciseEditingComponents.swift"),
    encoding: .utf8
)

precondition(
    !FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent("PeakLog/Views/Training/PlanDayPreviewSection.swift").path
    ),
    "Expected the read-only plan preview to be replaced by the interactive editor"
)
precondition(
    futureSource.contains("TodayPlannedExerciseCard(") && futureSource.contains("showsCompletionControl: false"),
    "Expected future days to reuse the today-plan exercise card without completion controls"
)
precondition(
    futureSource.contains("PlannedCardioCard(exercise: exercise, showsStartAction: false)"),
    "Expected future cardio cards to hide the start action"
)
precondition(
    !futureSource.contains("completePlannedSet"),
    "Expected future days to never complete sets"
)
precondition(
    futureSource.contains("training.future.addPlanExercise"),
    "Expected future days to keep the add-exercise entry"
)
precondition(
    futureSource.range(of: #"rest_day[\s\S]*?addExerciseRow"#, options: .regularExpression) != nil,
    "Expected rest days to keep the add-exercise entry too"
)
precondition(
    futureSource.contains("ReorderableExerciseList(") && futureSource.contains("reorderExercises("),
    "Expected future days to support long-press reordering"
)
precondition(
    componentsSource.contains("var showsCompletionControl: Bool = true")
        && componentsSource.contains("if showsCompletionControl {"),
    "Expected the shared set row to gate its completion control behind showsCompletionControl"
)

// 未来日之间切换必须重建 FutureDayContent（PR #115 review）：否则
// isReordering/draftOrder 跨日期泄漏，重排提交会把旧日期的动作 id
// 写到新选中的日期上。
let trainingScreenSource = try String(
    contentsOf: rootURL.appendingPathComponent("PeakLog/Views/Training/TrainingScreen.swift"),
    encoding: .utf8
)
precondition(
    trainingScreenSource.range(
        of: #"FutureDayContent\(tense: tense, historyViewModel: historyViewModel\)[\s\S]{0,400}?\.id\(Calendar\.current\.startOfDay\(for: historyViewModel\.selectedDate\)\)"#,
        options: .regularExpression
    ) != nil,
    "Expected FutureDayContent to be identity-keyed by the selected day so editing state resets across future dates"
)

print("future_day_editor_contract_test passed")
