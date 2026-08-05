import Foundation

// SUGGESTED 分区在一次挑选过程（两次进出配置页之间）里必须顺序固定：
// 行不重排、不因为被选中而消失，否则多选时手指落下去点到的是另一个动作。
// 该不变式的排序部分由 `ExerciseRecommendationEngine.stableMerge` 的单测覆盖
// （tests/exercise_recommendation_test.swift），这里固定视图侧的接线，防止
// 重新把 selection 折进任务 id、或让被取消的旧任务把过期结果写回去。

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let picker = try String(
    contentsOf: root.appendingPathComponent("PeakLog/Views/Today/ExercisePickerScreen.swift"),
    encoding: .utf8
)

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// 任务 id 只跟随配置页卡片（一次 pass），不跟随 selection——把 selection 折
// 进来就是「每点一下重排一次」的成因。
require(
    picker.contains(".task(id: pickingPassKey)"),
    "recommendations must refresh per picking pass, not per selection"
)
require(
    picker.contains("private var pickingPassKey: String {"),
    "picking pass key must exist"
)
let passKeyBody = picker
    .components(separatedBy: "private var pickingPassKey: String {")[1]
    .components(separatedBy: "}")[0]
require(
    !passKeyBody.contains("selection"),
    "picking pass key must not fold in the live selection"
)

// 排序由纯函数承载，视图不得直接把新排名赋给 recommendations。
require(
    picker.contains("ExerciseRecommendationEngine.stableMerge("),
    "suggested rows must go through the order-preserving merge"
)

// 被取消的旧任务仍会在 await 之后恢复（动作库服务不抛错也不查取消），
// 必须丢弃，否则会把上一个 pass 的排名（含已变成配置卡片的动作）钉住。
let refreshBody = picker.components(separatedBy: "private func refreshRecommendations() async {")[1]
require(
    refreshBody.contains("guard !Task.isCancelled else { return }"),
    "a superseded refresh must not publish its stale ranking"
)
// 注释里也会出现 "await"，先剥掉行注释再比位置。
let refreshCode = refreshBody
    .components(separatedBy: "\n")
    .map { $0.components(separatedBy: "//")[0] }
    .joined(separator: "\n")
let beforeFirstAwait = refreshCode.components(separatedBy: "await")[0]
require(
    beforeFirstAwait.contains("let passKey = pickingPassKey"),
    "the pass key must be captured before any await, so a late result cannot be stamped with a newer pass"
)

print("exercise_picker_suggestion_stability_test passed")
