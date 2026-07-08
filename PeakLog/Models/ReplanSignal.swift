import Foundation

/// A user-initiated mid-week adjustment signal (Phase 3). The raw values match
/// exactly the strings the `generate-weekly-plan` Edge Function accepts in its
/// `signal` field and the `plan_generations.signal` / `day_signal` event
/// payloads — keep them in sync with the server's REPLAN_SIGNALS set.
nonisolated enum ReplanSignal: String, CaseIterable, Codable, Sendable {
    case skipToday = "skip_today"
    case lowEnergy = "low_energy"
    case timeLimited = "time_limited"

    /// Localized label for the one-tap menu entry (Chinese default so it works
    /// before the string catalog is populated; the app's primary language).
    var menuTitle: String {
        switch self {
        case .skipToday: return String(localized: "today.replan.skip_today", defaultValue: "跳过今天")
        case .lowEnergy: return String(localized: "today.replan.low_energy", defaultValue: "状态不好")
        case .timeLimited: return String(localized: "today.replan.time_limited", defaultValue: "时间有限")
        }
    }

    var menuIcon: String {
        switch self {
        case .skipToday: return "moon.zzz"
        case .lowEnergy: return "battery.25"
        case .timeLimited: return "clock.badge.exclamationmark"
        }
    }

    /// Signals that only make sense for *today* itself, so they must be
    /// disabled once today already has a completed set (the server's C31 would
    /// reject them anyway; graying out avoids a pointless round trip). Low
    /// energy still applies — it auto-scopes to the next eligible day.
    var requiresUntrainedToday: Bool {
        switch self {
        case .skipToday, .timeLimited: return true
        case .lowEnergy: return false
        }
    }
}
