import Foundation

// 训练进行中「快速改重量 / 次数」的结构契约。
//
// 与 `plan_focus_training_mode_test.swift` 同一套路：`TodayWorkoutViewModel.swift`
// 拉进来的依赖图太大，没法用 `swiftc` 单独编译，所以这里直接读源码断言接线是否还在。
// 真正的运行时行为（改过的值才是落库的那份、已落库的组拒绝修改、连点合并成一次写入、
// 取值规则）由 `PeakLogTests/TodayWorkoutLiveSessionTests` 与
// `PeakLogTests/QuickSetAdjustmentTests` 在 `xcodebuild test` 下覆盖。

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func source(_ path: String) throws -> String {
    try String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8)
}

let modelsSource = try source("PeakLog/Models/PlanLiveWorkoutModels.swift")
let adjustmentSource = try source("PeakLog/Models/QuickSetAdjustment.swift")
let viewModelSource = try source("PeakLog/ViewModels/TodayWorkoutViewModel.swift")
let componentsSource = try source("PeakLog/Views/Today/TrainingFocusComponents.swift")
let screenSource = try source("PeakLog/Views/Today/TodayWorkoutScreen.swift")

// 组的目标值必须是 `var`：session 快照就是 confirm 时落库的那份，它不可变就等于
// 训练中改的任何数都到不了训练记录里。
precondition(
    modelsSource.contains("var targetWeight: Double?") && modelsSource.contains("var targetReps: Int"),
    "Expected the live session's set targets to be mutable mid-workout"
)

// 取值规则只能有一份实现：UI 算下一档、view model 落库前钳制，用的必须是同一套。
precondition(
    adjustmentSource.contains("enum QuickSetAdjustment")
        && adjustmentSource.contains("func weightStep(for unit: WeightUnit)")
        && adjustmentSource.contains("func adjustedWeight(")
        && adjustmentSource.contains("func adjustedReps("),
    "Expected a single shared source of truth for the quick +/- stepping rules"
)
precondition(
    componentsSource.contains("QuickSetAdjustment.adjustedWeight")
        && componentsSource.contains("QuickSetAdjustment.adjustedReps"),
    "Expected the focus card's steppers to step through QuickSetAdjustment, not re-derive the increments"
)
precondition(
    viewModelSource.contains("QuickSetAdjustment.clampedWeight")
        && viewModelSource.contains("QuickSetAdjustment.clampedReps"),
    "Expected the view model to clamp incoming values through the same rules"
)

// view model 侧的接口：改 session（决定落库值）+ 改计划（决定退出专注模式后看到的值）。
precondition(
    viewModelSource.contains("func updateLiveWorkoutSet(setId: String, targetWeight: Double?, targetReps: Int)"),
    "Expected a view-model entry point for editing a live set's target"
)
precondition(
    viewModelSource.contains("updatePlanSetInPlace(planSetId: setId)"),
    "Expected the quick edit to update today's plan optimistically as well as the session"
)
precondition(
    viewModelSource.contains("guard !current.isAlreadyCompleted else { return nil }"),
    "Expected sets logged before the session started to reject target edits"
)

// 最小化训练时用户仍能在普通计划卡上改同一组。confirm 落库读的是 session 快照，
// 所以那条路径也必须打进快照，否则那次编辑会在结束训练时被静默丢掉。
func callsSessionMirror(inFunctionNamed name: String) -> Bool {
    guard let range = viewModelSource.range(of: "func \(name)") else { return false }
    return viewModelSource[range.upperBound...].prefix(2_000).contains("applyTargetToLiveSession(")
}

for entryPoint in ["updateLiveWorkoutSet(", "updatePlannedSet("] {
    precondition(
        callsSessionMirror(inFunctionNamed: entryPoint),
        "Expected \(entryPoint) to write the new target into the live session snapshot"
    )
}

// 写库去抖：`+` 是连点操作，每一下都发一次写请求既浪费，完成顺序又不受控。
precondition(
    viewModelSource.contains("private var planSetTargetWriteTask: Task<Void, Never>?")
        && viewModelSource.contains("planSetTargetWriteTask?.cancel()"),
    "Expected the plan write-through to be debounced so rapid taps collapse into one write"
)
precondition(
    viewModelSource.contains("func flushPendingPlanSetTargets() async"),
    "Expected a flush entry point so pending edits can be forced out before they'd be lost"
)

func flushIsCalled(inFunctionNamed name: String) -> Bool {
    guard let range = viewModelSource.range(of: "func \(name)") else { return false }
    return viewModelSource[range.upperBound...].prefix(2_000).contains("flushPendingPlanSetTargets()")
}

for entryPoint in [
    "confirmPlanLiveWorkout() async",
    "cancelPlanLiveWorkout()",
    "flushPendingLiveWorkoutPersistence()"
] {
    precondition(
        flushIsCalled(inFunctionNamed: entryPoint),
        "Expected \(entryPoint) to flush pending target writes — otherwise an edit can be lost"
    )
}

// UI 接线：卡片把 setId 透传上去，行上同时有快速档（±）和精确档（轮盘）。
precondition(
    screenSource.contains("onUpdateSet: onUpdateLiveSet")
        && screenSource.contains("viewModel.updateLiveWorkoutSet("),
    "Expected the focus card's edit callback to reach the view model"
)
precondition(
    componentsSource.contains("training_focus.weightDown.")
        && componentsSource.contains("training_focus.weightUp.")
        && componentsSource.contains("training_focus.repsDown.")
        && componentsSource.contains("training_focus.repsUp."),
    "Expected +/- controls for both weight and reps on the current set"
)
precondition(
    componentsSource.contains("WeightWheelEditSheet") && componentsSource.contains("RepsWheelEditSheet"),
    "Expected the precise path to reuse the existing wheel sheets instead of a second editor"
)

// 无障碍标签必须两种语言都有；只加 key 不加翻译，VoiceOver 会念出 key 本身。
let catalogData = try Data(contentsOf: rootURL.appendingPathComponent("PeakLog/Localizable.xcstrings"))
let catalog = try JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
let strings = catalog?["strings"] as? [String: Any] ?? [:]

for key in [
    "training_session.quick_edit.weight_down",
    "training_session.quick_edit.weight_up",
    "training_session.quick_edit.reps_down",
    "training_session.quick_edit.reps_up"
] {
    let entry = strings[key] as? [String: Any]
    let localizations = entry?["localizations"] as? [String: Any] ?? [:]
    precondition(
        localizations["en"] != nil && localizations["zh-Hans"] != nil,
        "Expected \(key) to be translated in both en and zh-Hans"
    )
    precondition(
        componentsSource.contains(key),
        "Expected \(key) to actually be used by the focus card"
    )
}

print("quick_set_edit_contract_test passed")
