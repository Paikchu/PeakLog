import Foundation

// `PlanLiveActivityAttributes` 和 Widget 扩展都在 `#if canImport(ActivityKit)` 之后，
// 主机 swiftc 编译不到（见 `live_activity_manager_safety_test.swift` 开头的说明），
// 所以这里沿用同目录的既有约定：对源码做文本断言，盯住灵动岛信息层级重设计里几条
// 一旦回退就会静默失效的契约。
//
// 运行：
//   swiftc -O -o /tmp/live_activity_hierarchy_test \
//     tests/live_activity_information_hierarchy_test.swift && /tmp/live_activity_hierarchy_test

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func source(_ path: String) throws -> String {
    try String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8)
}

let attributesSource = try source("PeakLogShared/PlanLiveActivityAttributes.swift")
let widgetSource = try source("PeakLogLiveActivityExtension/PeakLogLiveActivityBundle.swift")
let managerSource = try source("PeakLog/Services/LiveActivityManager.swift")

// MARK: - P1：当前动作剩余组数必须随 state 下发

// 不能让 Widget 从 `attributes.exercises` 反推剩余组数：`trimmedAttributes` 为了 4KB
// 预算会裁掉尾部动作，当前动作有可能根本不在 attributes 里，反推会算出 0。
precondition(
    attributesSource.contains("let currentExerciseRemainingSets: Int"),
    "Expected ContentState to carry the current exercise's remaining set count"
)
precondition(
    attributesSource.contains("currentExerciseRemainingSets: exercise.sets.count { !completed.contains($0.id) }"),
    "Expected remaining sets to be counted off the session's completed set IDs"
)
precondition(
    widgetSource.contains("state.currentExerciseRemainingSets"),
    "Expected the Dynamic Island to render the remaining set count"
)

// MARK: - P2：进度分母必须是裁剪前的总数

// 裁掉的动作里可能已经有完成的组，用裁剪后的 `totalSetsCount` 当分母会算出超过
// 100% 的进度——文字上是 18/16，画成进度环就是转过头的一圈。
precondition(
    attributesSource.contains("let plannedTotalSetsCount: Int?"),
    "Expected attributes to carry the untrimmed planned set total"
)
precondition(
    attributesSource.contains("var progressTotalSetsCount: Int"),
    "Expected a progress denominator that survives attribute trimming"
)
precondition(
    !attributesSource.contains("totalSetsCount: attributes.totalSetsCount"),
    "Expected ContentState to use the untrimmed denominator, not the post-trim total"
)
precondition(
    managerSource.contains("plannedTotalSetsCount: session.totalSetsCount"),
    "Expected the manager to seed the denominator from the untrimmed session"
)

// MARK: - P3：紧凑态左槽是动作简称

precondition(
    attributesSource.contains("PlanLiveActivityShortName.make(from:"),
    "Expected ContentState to precompute the compact-leading short name"
)
precondition(
    widgetSource.contains("state.currentExerciseShortName"),
    "Expected compactLeading to render the short name"
)

// MARK: - 复合件按优先级降级

// P1 + P2 是同一个复合件，紧凑态和最小态复用它，所以最小态被丢掉的恰好是 P3。
// 如果哪天最小态改回只画一个对勾，这条会挂。
precondition(
    widgetSource.contains("private func remainingRing("),
    "Expected a single ring component shared by the compact and minimal presentations"
)
if let compactRange = widgetSource.range(of: "} compactTrailing: {"),
   let minimalRange = widgetSource.range(of: "} minimal: {") {
    let compactTrailing = widgetSource[compactRange.upperBound..<minimalRange.lowerBound]
    let minimal = widgetSource[minimalRange.upperBound...]
    precondition(
        compactTrailing.contains("remainingRing("),
        "Expected compactTrailing to use the shared ring"
    )
    precondition(
        minimal.contains("remainingRing("),
        "Expected minimal to degrade to the same ring rather than dropping P1/P2"
    )
} else {
    preconditionFailure("Expected both compactTrailing and minimal presentations")
}

// MARK: - 向后兼容解码

// App 升级时系统里可能还留着上一版编码的 Activity。缺 key 直接抛错会让它从
// `Activity.activities` 里消失，而 update/end 都靠遍历那份注册表找 handle——结果是
// 灵动岛卡在旧内容上，App 既刷不新也结束不掉。
// 折掉空白再比对，免得断言被一次换行重排搞挂。
let collapsedAttributes = attributesSource.filter { !$0.isWhitespace }
for (key, type) in [
    ("currentExerciseShortName", "String"),
    ("currentExerciseRemainingSets", "Int"),
    ("currentExerciseTotalSets", "Int"),
] {
    precondition(
        collapsedAttributes.contains("decodeIfPresent(\(type).self,forKey:.\(key))"),
        "Expected \(key) to decode with decodeIfPresent + fallback for pre-upgrade activities"
    )
}

// MARK: - 进度比例必须夹在 0...1

// 分母修好之后理论上不会溢出，但 completedSetIDs 来自跨进程的 App Group，
// 环画出去一圈的代价比一次 min/max 大得多。
precondition(
    widgetSource.contains("min(max(fraction, 0), 1)"),
    "Expected the progress fraction to be clamped before it drives the ring"
)

// MARK: - 无障碍

// 复合件把三条信息叠在一个圆里，VoiceOver 必须能读出完整语义。
precondition(
    widgetSource.contains(".accessibilityElement(children: .ignore)")
        && widgetSource.contains(".accessibilityLabel(accessibilityLabel(state))"),
    "Expected the ring to expose one composed accessibility label"
)

print("live_activity_information_hierarchy_test passed")
