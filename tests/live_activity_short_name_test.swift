import Foundation

// `PlanLiveActivityShortName` 刻意放在 ActivityKit 门禁之外的独立文件里，就是为了能被
// 主机 swiftc 直接编译执行——灵动岛紧凑态左槽的可读性完全取决于这条缩写规则，只做
// 文本断言（本目录里其他 ActivityKit 相邻测试的做法）盯不住它。
//
// 运行：本文件是顶层代码,一旦和别的 .swift 一起编译就不再被当成脚本
// (报 expressions are not allowed at the top level),所以要先改名成 main.swift：
//   d=$(mktemp -d) && cp tests/live_activity_short_name_test.swift "$d/main.swift" && \
//     swiftc -O -o "$d/t" "$d/main.swift" PeakLogShared/PlanLiveActivityShortName.swift && "$d/t"

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// MARK: - 逐条规则断言

// 已经够短就原样保留：保留器械词能把同一天里的两个变式区分开
// （「杠铃卧推」不会和「上斜哑铃卧推」撞成同一个「卧推」）。
precondition(PlanLiveActivityShortName.make(from: "杠铃卧推") == "杠铃卧推")
precondition(PlanLiveActivityShortName.make(from: "俯卧撑") == "俯卧撑")
precondition(PlanLiveActivityShortName.make(from: "引体向上") == "引体向上")

// 超长时先删器械，角度这类区分性修饰留到最后才删。
precondition(PlanLiveActivityShortName.make(from: "上斜哑铃卧推") == "上斜卧推")
precondition(PlanLiveActivityShortName.make(from: "上斜杠铃卧推") == "上斜卧推")
precondition(PlanLiveActivityShortName.make(from: "单臂哑铃划船") == "单臂划船")
precondition(PlanLiveActivityShortName.make(from: "史密斯卧推") == "卧推")

// 删无可删时退到核心动作词。
precondition(PlanLiveActivityShortName.make(from: "罗马尼亚硬拉") == "硬拉")
precondition(PlanLiveActivityShortName.make(from: "保加利亚分腿蹲") == "分腿蹲")
precondition(PlanLiveActivityShortName.make(from: "高脚杯深蹲") == "深蹲")
precondition(PlanLiveActivityShortName.make(from: "颈后臂屈伸") == "臂屈伸")

// 位于词尾的修饰词是动作本身，不能当器械前缀删掉——删了「反向蝴蝶机」只剩「反向」。
precondition(PlanLiveActivityShortName.make(from: "反向蝴蝶机") == "蝴蝶机")

// 拉丁文动作名同样是修饰在前、动作在后，取词尾一个词。
precondition(PlanLiveActivityShortName.make(from: "Incline Barbell Bench Press") == "Press")
precondition(PlanLiveActivityShortName.make(from: "Pull-Up") == "Up")

// 空名字不能崩，也不能造出一个假名字——Widget 侧遇到空串会回落到图标。
precondition(PlanLiveActivityShortName.make(from: "") == "")
precondition(PlanLiveActivityShortName.make(from: "   ") == "")

// MARK: - 动作库全量扫描

// 规则对全库每一条都必须给出 2–4 个字：少于 2 字没有信息量，多于 4 字在 44 pt 宽的
// 紧凑态左槽里会被缩到看不清。用户自建动作走同一条规则，所以这里过了就等于覆盖了
// 「从库里选的动作」这条主路径。
struct LibraryFile: Decodable {
    struct Entry: Decodable {
        let nameZH: String
        let nameEN: String
        let popularity: Int
    }
    let exercises: [Entry]
}

let libraryURL = rootURL.appendingPathComponent("PeakLog/Resources/exercise_library.json")
let library = try JSONDecoder().decode(LibraryFile.self, from: Data(contentsOf: libraryURL))
precondition(library.exercises.count > 1000, "动作库条目异常少，检查资源路径")

var outOfRange: [(String, String)] = []
for entry in library.exercises {
    let short = PlanLiveActivityShortName.make(from: entry.nameZH)
    if short.count < 2 || short.count > PlanLiveActivityShortName.characterLimit {
        outOfRange.append((entry.nameZH, short))
    }
    // 英文名走另一条分支，同样不能产出空串。
    precondition(
        !PlanLiveActivityShortName.make(from: entry.nameEN).isEmpty,
        "英文动作名 \(entry.nameEN) 缩写成了空串"
    )
}

precondition(
    outOfRange.isEmpty,
    "以下动作缩写越界（应为 2–4 字）：\(outOfRange.prefix(10))"
)

// 简称是删词得到的，未必是连续子串（「上斜哑铃卧推」→「上斜卧推」），但绝不能引入
// 原名里没有的字——那说明词表拼接出了一个不存在的动作。
let fabricated = library.exercises.filter { entry in
    !Set(PlanLiveActivityShortName.make(from: entry.nameZH)).isSubset(of: Set(entry.nameZH))
}
precondition(
    fabricated.isEmpty,
    "以下简称引入了原名里没有的字：\(fabricated.prefix(5).map(\.nameZH))"
)

print("live_activity_short_name_test passed (\(library.exercises.count) exercises)")
