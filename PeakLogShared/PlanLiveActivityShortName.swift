import Foundation

/// 把动作名压成 2–4 个字的简称，给灵动岛紧凑态的左槽用。
///
/// 紧凑态左槽只有约 44 pt 宽，放不下「上斜哑铃卧推」这种完整名字；直接截断又会把
/// 信息量最大的部分切掉（中文动作名是修饰语在前、动作在后）。这里用纯函数做规则化
/// 缩写，App 侧构造 `ContentState` 时算好，Widget 扩展拿到的是成品字符串。
///
/// 刻意不查动作库：用户手输的自建动作没有库条目，但同样要显示；规则只依赖名字本身，
/// 两种来源走同一条路径。
///
/// 规则四步，命中即停：
/// 1. `overrides` —— 规则读不通的少数动作，人工指定。
/// 2. 逐层删除修饰词：器械 → 体位 → 肢体/握法。信息量最低的先删。
/// 3. 匹配 `movementTerms` 里最长的词尾，取核心动作词。
/// 4. 兜底截取末 `characterLimit` 个字。
///
/// 规则在 `tests/live_activity_short_name_test.swift` 里对动作库全量 1328 条断言：
/// 每条都必须落在 2–4 字之间。
nonisolated enum PlanLiveActivityShortName {
    /// 简称字数上限。再长 SwiftUI 就得把字缩到看不清了。
    static let characterLimit = 4

    /// 删修饰词时保留的最小字数，避免把「哑铃」删成空串。
    static let minimumCharacterCount = 2

    /// 拉丁文动作名取词尾后的字符上限（拉丁字形约半个汉字宽）。
    static let latinCharacterLimit = 10

    static func make(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let override = overrides[trimmed] {
            return override
        }

        guard containsCJK(trimmed) else {
            return latinShortName(trimmed)
        }

        var result = trimmed
        for tier in modifierTiers {
            if result.count <= characterLimit { return result }
            for token in tier {
                if result.count <= characterLimit { break }
                result = removingModifier(token, from: result)
            }
        }

        if result.count <= characterLimit { return result }

        if let term = sortedMovementTerms.first(where: {
            $0.count <= characterLimit && result.hasSuffix($0)
        }) {
            return term
        }

        return String(result.suffix(characterLimit))
    }

    /// 删除一个修饰词。位于词尾的不删——「反向蝴蝶机」里的蝴蝶机是动作本身，
    /// 不是器械前缀，删掉只剩「反向」就没有信息了。
    private static func removingModifier(_ token: String, from name: String) -> String {
        guard !name.hasSuffix(token),
              name.count - token.count >= minimumCharacterCount,
              let range = name.range(of: token) else { return name }

        var result = name
        result.removeSubrange(range)
        return result
    }

    /// 拉丁文动作名同样是修饰在前、动作在后（Incline Barbell Bench **Press**），
    /// 取词尾一个词。
    private static func latinShortName(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "\u{00A0}" })
        guard let last = words.last else {
            return String(name.prefix(latinCharacterLimit))
        }
        return String(last.prefix(latinCharacterLimit))
    }

    private static func containsCJK(_ name: String) -> Bool {
        name.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    /// 规则给不出可读结果的动作。只收规则确实读不通的，不做全库策展——
    /// 全库策展的维护成本会随动作库增长，而规则对新动作自动生效。
    private static let overrides: [String: String] = [
        "杠铃反握颅骨粉碎者": "碎颅者",
        "杠铃后束三角肌上举": "后束上举",
        "杠铃滚轮前推自卧凳": "滚轮前推",
        "杠铃卧凳前蹲": "前蹲",
        "哑铃仰卧旋前": "旋前",
        "哑铃仰卧旋后": "旋后",
        "哑铃仰卧股": "仰卧股",
        "地雷管180": "地雷管",
        "45度体侧屈": "体侧屈",
    ]

    /// 删除优先级从高到低。器械最先删（在健身房里你手上拿着什么自己看得见），
    /// 肢体/握法最后删（可能是同一天里区分两个动作的唯一信息）。
    private static let modifierTiers: [[String]] = [
        ["史密斯机", "史密斯", "蝴蝶机", "龙门架", "弹力带", "瑞士球", "药球", "壶铃", "杠铃",
         "哑铃", "绳索", "滑轮", "器械", "机械", "罗马椅", "杠片", "悬吊带", "臂力器",
         "健腹轮", "战绳", "跳箱", "曲杆", "直杆", "徒手"],
        ["坐姿", "站姿", "跪姿", "俯身", "高位", "低位", "仰卧", "俯卧"],
        ["单臂", "双臂", "单腿", "双腿", "窄距", "宽距", "宽握", "窄握", "正手", "反手",
         "交替", "慢速"],
    ]

    /// 核心动作词。删完修饰词还超长时，从词尾匹配最长的一个。
    private static let movementTerms: [String] = [
        "引体向上", "平板支撑", "仰卧起坐", "仰卧上拉", "十字夹胸", "反向飞鸟", "后束飞鸟",
        "臂屈伸", "腿屈伸", "腿弯举", "髋屈伸", "分腿蹲", "箭步蹲", "俯卧撑", "侧平举",
        "前平举", "体侧屈", "蝴蝶机", "早安式", "体前屈",
        "面拉", "硬拉", "深蹲", "卧推", "划船", "推举", "下拉", "弯举", "飞鸟", "夹胸",
        "臀推", "腿举", "提踵", "耸肩", "卷腹", "转体", "下压", "推胸", "肩推", "过头",
        "举腿", "臀桥", "支撑", "摆动", "挺身", "蹬腿", "外展", "内收", "伸展", "下蹲",
        "跳跃", "抬腿", "踢腿", "弓步", "前蹲", "抓举", "挺举", "翻站",
    ]

    private static let sortedMovementTerms: [String] = movementTerms.sorted { $0.count > $1.count }
}
