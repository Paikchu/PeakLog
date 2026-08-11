import Foundation

// 训练进行中「快速改重量 / 次数」的取值规则。
//
// 纯值计算并标记 `nonisolated`：组行（View）用它算出下一档的值，view model 用同一套
// 规则做落库前的钳制。两边必须共用一份实现——如果 UI 按 2.5 递增、view model 按别的
// 规则钳制，用户看到的数和真正记进训练里的数就会分叉。

nonisolated enum QuickSetAdjustment {
    /// 一次 `+` / `−` 的负重增量：kg 走 2.5（杠铃两端各一片 1.25kg 的最小可加量），
    /// lbs 走 5（两端各 2.5lb）。不做"按当前重量百分比"这类自适应步长：训练时用户
    /// 需要的是可预期的手感，而不是每组都要重新猜这一下加了多少。
    static func weightStep(for unit: WeightUnit) -> Double {
        switch unit {
        case .kg: return 2.5
        case .lbs: return 5
        }
    }

    static let repsStep = 1
    static let minimumReps = 1

    /// 负重轮（`WeightWheelEditSheet`）的最小刻度。快速调整落在同一张网格上，
    /// 才不会出现"轮盘选不中、只能看不能改"的值。
    private static let weightGrid = 0.25

    /// 按档位调整负重。
    ///
    /// - Parameter allowsUnset: 自重动作传 true。此时减到 0 以下回到 `nil`＝纯自重，
    ///   反过来 `nil` 起步按 0 计算，第一次 `+` 就是"自重 +2.5kg"。非自重动作钳在 0，
    ///   0 是有意义的（空杆、助力器械），不该被吞成"未设置"。
    static func adjustedWeight(
        _ current: Double?,
        steps: Int,
        unit: WeightUnit,
        allowsUnset: Bool
    ) -> Double? {
        let raw = (current ?? 0) + Double(steps) * weightStep(for: unit)
        // 反复 +/- 的浮点累加会漂（0.1 + 0.2 != 0.3），每次都吸附回刻度网格。
        let snapped = (raw / weightGrid).rounded() * weightGrid
        guard snapped > 0 else { return allowsUnset ? nil : 0 }
        return snapped
    }

    /// 按档位调整次数；不允许降到 0——0 次的"组"没有意义，要放弃这一组用的是跳过。
    static func adjustedReps(_ current: Int, steps: Int) -> Int {
        max(minimumReps, current + steps * repsStep)
    }

    /// 落库前的兜底钳制。UI 已经按上面的规则算过，但 view model 的入口是 public 的，
    /// 不能假设调用方一定守规矩。
    static func clampedWeight(_ weight: Double?) -> Double? {
        weight.map { max(0, $0) }
    }

    static func clampedReps(_ reps: Int) -> Int {
        max(minimumReps, reps)
    }
}
