import Foundation

// 今日训练里改一组的重量 / 次数,必须走轮盘选择器 sheet 并显式提交,不是裸的
// 数字键盘输入框。
//
// 这个测试原本盯的是 `ExerciseCardView` 里数字键盘的 `ToolbarItemGroup(placement:
// .keyboard)` —— 那是文本输入时代唯一能"收起键盘再提交"的地方。`aed6930`
// (2026-07-07) 把重量/次数换成轮盘选择器后,键盘和它的工具栏一起没了,断言
// 却留在原地,于是这个用例从那天起一直红着、也不再保护任何东西。
//
// 重写后盯的是替代方案本身的契约:入口是 sheet、提交走 onCommit、取消不落值。
// 键盘收起这件事本身另有 `keyboard_dismiss_action_test` 覆盖。
//
// 运行:swiftc tests/today_value_edit_sheet_test.swift -o /tmp/tves && /tmp/tves

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func source(_ path: String) throws -> String {
    try String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8)
}

let cardSource = try source("PeakLog/Views/Today/ExerciseCardView.swift")
let sheetSource = try source("PeakLog/Views/Today/WheelValueEditSheet.swift")

// 1. 两个值各自有轮盘 sheet,而不是共用一个"随便填"的输入框。
precondition(
    sheetSource.contains("struct WeightWheelEditSheet"),
    "Expected a dedicated wheel sheet for weight editing"
)
precondition(
    sheetSource.contains("struct RepsWheelEditSheet"),
    "Expected a dedicated wheel sheet for reps editing"
)

// 2. `ExerciseCardView` 用 sheet 呈现它们 —— 保证改值是一次有始有终的编辑,
//    而不是行内即时生效。
precondition(
    cardSource.contains(".sheet(isPresented: $editingWeight)")
        && cardSource.contains("WeightWheelEditSheet("),
    "Expected ExerciseCardView to present the weight wheel sheet"
)
precondition(
    cardSource.contains(".sheet(isPresented: $editingReps)")
        && cardSource.contains("RepsWheelEditSheet("),
    "Expected ExerciseCardView to present the reps wheel sheet"
)

// 3. 回归护栏:重量/次数不能退回成裸 TextField —— 那正是这次重写要挡住的形态。
precondition(
    !cardSource.contains("TextField"),
    "Set values must be edited through the wheel sheets, not a raw TextField"
)
precondition(
    !cardSource.contains(".keyboardType(.numberPad)")
        && !cardSource.contains(".keyboardType(.decimalPad)"),
    "A number pad here means the wheel picker was reverted; see aed6930"
)

/// 取出 `marker` 之后那一对花括号里的内容。
///
/// 刻意做真正的配对,而不是"从 marker 起取 N 个字符"—— 后者的红/绿取决于被测
/// 代码有多长,而不是它做了什么。同目录的 `today_workout_persist_debounce_test`
/// 正是栽在这上面:一次无关的函数体增长就把断言推出了固定窗口。
func braceBody(after marker: String, in haystack: Substring) -> Substring? {
    guard let start = haystack.range(of: marker) else { return nil }
    guard let open = haystack[start.upperBound...].firstIndex(of: "{") else { return nil }

    var depth = 0
    var index = open
    while index < haystack.endIndex {
        switch haystack[index] {
        case "{": depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return haystack[haystack.index(after: open)..<index]
            }
        default: break
        }
        index = haystack.index(after: index)
    }
    return nil
}

func braceBody(after marker: String) -> Substring? {
    braceBody(after: marker, in: cardSource[...])
}

// 4. 两个 sheet 都必须把新值经 onCommit 交回卡片并关闭自己;取消分支只关闭,
//    不写值 —— 否则"取消"会静默落库。
for (label, marker) in [("weight", ".sheet(isPresented: $editingWeight)"),
                        ("reps", ".sheet(isPresented: $editingReps)")] {
    guard let body = braceBody(after: marker) else {
        preconditionFailure("Expected a \(label) sheet block in ExerciseCardView")
    }
    precondition(
        body.contains("onCommit("),
        "Expected the \(label) sheet to hand its value back through onCommit"
    )

    // 「有个 onCancel: 标签」不等于「取消不落值」——只断言标签存在的话,某天
    // onCancel 里多出一次 onCommit(...) 或 set.weight = ... 这个测试照样是绿的,
    // 而"取消却静默落库"正是这段注释声称要挡住的事。所以真正去看闭包体。
    guard let cancelBody = braceBody(after: "onCancel:", in: body) else {
        preconditionFailure("Expected the \(label) sheet to expose a cancel branch")
    }
    precondition(
        !cancelBody.contains("onCommit("),
        "The \(label) sheet's cancel branch must not commit — that is a silent save on Cancel"
    )
    precondition(
        !cancelBody.contains("set.weight") && !cancelBody.contains("set.reps"),
        "The \(label) sheet's cancel branch must not mutate the set — cancelling has to leave the value untouched"
    )
    // 剩下的只该是"把自己关掉"。
    precondition(
        cancelBody.contains("editing"),
        "Expected the \(label) sheet's cancel branch to dismiss the editor"
    )
}

print("today_value_edit_sheet_test passed")
