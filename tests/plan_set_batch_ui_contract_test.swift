import Foundation

// 批量调节计划组目标的 UI 接线契约。轮盘面板多了一个「应用到所有未完成组」
// 开关，勾选后「完成」提交的是一次批量调节而不是单组修改。
// 运行：swiftc tests/plan_set_batch_ui_contract_test.swift -o /tmp/bui && /tmp/bui

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func source(_ path: String) throws -> String {
    try String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8)
}

let sheetSource = try source("PeakLog/Views/Today/WheelValueEditSheet.swift")
let componentsSource = try source("PeakLog/Views/Today/PlanExerciseEditingComponents.swift")
let todaySource = try source("PeakLog/Views/Today/TodayWorkoutScreen.swift")
let futureSource = try source("PeakLog/Views/Training/FutureDayContent.swift")

// 1. 批量回调必须排在 onCancel 之后。既有三个调用点用尾随闭包传 onDone /
// onCancel（SE-0279 按声明顺序匹配），把新参数插到它们前面会让尾随闭包
// 静默绑到错误的参数上——编译得过，行为全错。
for (name, marker) in [("weight", "var onDone: (Double?) -> Void"), ("reps", "var onDone: (Int) -> Void")] {
    guard let doneRange = sheetSource.range(of: marker),
          let cancelRange = sheetSource.range(of: "var onCancel: () -> Void", range: doneRange.upperBound..<sheetSource.endIndex),
          let batchRange = sheetSource.range(of: "var onDoneApplyingToAllSets", range: cancelRange.upperBound..<sheetSource.endIndex)
    else {
        fatalError("\(name) sheet must declare onDoneApplyingToAllSets after onDone/onCancel")
    }
    precondition(cancelRange.upperBound <= batchRange.lowerBound)
}

// 2. 开关整行只在调用方提供批量回调时出现，且文案走本地化 key。
precondition(
    sheetSource.contains("if let applyToAllSets {") && sheetSource.contains("today.plan.batch.apply_to_all"),
    "The wheel chrome must render the localized apply-to-all switch only when a batch handler exists"
)
precondition(
    sheetSource.components(separatedBy: "applyToAllSets: onDoneApplyingToAllSets == nil ? nil : $appliesToAllSets").count == 3,
    "Both wheel sheets must gate the switch on having a batch handler"
)

// 3. 勾选后走批量回调，没勾还是单组回调——两条分支都必须在。
precondition(
    sheetSource.components(separatedBy: "if appliesToAllSets, let onDoneApplyingToAllSets").count == 3,
    "Both wheel sheets must route Done through the batch handler only while the switch is on"
)

// 4. 开关的出现条件：本动作还剩 2 组以上未完成，且当前这组自己未完成。
// 批量写入跳过已完成组，affordance 不能承诺它做不到的事。
precondition(
    componentsSource.contains("exercise.sets.count(where: { !$0.isCompleted }) > 1"),
    "The card must only offer batch editing while more than one set is still unfinished"
)
precondition(
    componentsSource.contains("self.set.isCompleted ? nil : onBatchCommit"),
    "A completed set's editor must not offer the batch switch"
)

// 5. 提交的调节只动被编辑的那一维：改重量不碰次数，改次数不碰重量。
precondition(
    componentsSource.contains("PlannedSetBatchAdjustment(weight: .uniform(weight, unit: set.targetWeightUnit))"),
    "The weight sheet must submit a weight-only batch adjustment"
)
precondition(
    componentsSource.contains("PlannedSetBatchAdjustment(reps: .uniform(reps))"),
    "The reps sheet must submit a reps-only batch adjustment"
)

// 6. 今日页与未来日两个宿主都把批量接到各自的 ViewModel 上。
precondition(
    todaySource.contains("viewModel.batchUpdatePlannedSets("),
    "Today screen must forward batch adjustments to TodayWorkoutViewModel"
)
precondition(
    futureSource.contains("editor.batchUpdateSets("),
    "Future day editor must forward batch adjustments to FutureDayPlanEditorViewModel"
)

// 7. 文案两种语言都要有，否则 zh-Hans 下会露出英文 key。
let catalog = try source("PeakLog/Localizable.xcstrings")
guard let entry = catalog.range(of: #""today\.plan\.batch\.apply_to_all"[\s\S]{0,600}?"zh-Hans"[\s\S]{0,200}?"value""#, options: .regularExpression) else {
    fatalError("today.plan.batch.apply_to_all must be localized for zh-Hans")
}
precondition(catalog[entry].contains("en"), "the batch switch string must also carry an en value")

print("plan_set_batch_ui_contract_test passed")
