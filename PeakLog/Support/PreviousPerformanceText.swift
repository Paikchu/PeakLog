import Foundation

/// 把「上一次练这个动作的所有组」压成一行能塞进专注卡片的文本。
/// 纯函数，无本地化依赖（数字与单位本身跨语言一致），由调用方在前面拼
/// "上次 / Last" 前缀。
nonisolated enum PreviousPerformanceText {
    /// 最多展示的组数；超出的部分折成 "+N"，避免长动作把卡片撑开。
    static let maxListedSets = 4

    /// - 全部组重量与次数都相同：`60 kg × 8 × 3` （末位是组数）
    /// - 否则逐组列出：`60 kg × 8, 60 × 8, 57.5 × 6`（单位只出现一次）
    /// - 无重量（自重等）：`× 12, × 10`
    /// - 空数组返回 nil。
    static func summary(from sets: [ExerciseSet]) -> String? {
        guard !sets.isEmpty else { return nil }

        let ordered = sets.sorted { $0.setIndex < $1.setIndex }
        let unitLabel = ordered.first(where: { $0.weight != nil })?.weightUnit.display

        // 同重同次的常见情况压成一行，别让 5 组一模一样的数字刷屏。
        let isUniform = ordered.allSatisfy { candidate in
            candidate.reps == ordered[0].reps
                && candidate.weight == ordered[0].weight
                && candidate.weightUnit == ordered[0].weightUnit
        }
        if isUniform {
            let head = component(for: ordered[0], unitLabel: unitLabel)
            return ordered.count > 1 ? "\(head) × \(ordered.count)" : head
        }

        let listed = ordered.prefix(maxListedSets)
        var parts: [String] = []
        for (index, set) in listed.enumerated() {
            // 单位只在第一项出现，后面靠上下文读数。
            parts.append(component(for: set, unitLabel: index == 0 ? unitLabel : nil))
        }
        var text = parts.joined(separator: ", ")
        let overflow = ordered.count - listed.count
        if overflow > 0 {
            text += " +\(overflow)"
        }
        return text
    }

    private static func component(for set: ExerciseSet, unitLabel: String?) -> String {
        guard let weight = set.weight else {
            return "× \(set.reps)"
        }
        let value = formatted(weight)
        guard let unitLabel else {
            return "\(value) × \(set.reps)"
        }
        return "\(value) \(unitLabel) × \(set.reps)"
    }

    private static func formatted(_ weight: Double) -> String {
        weight.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(weight))
            : String(format: "%.1f", weight)
    }
}
