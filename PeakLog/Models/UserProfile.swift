import Foundation

// MARK: - User Stats
nonisolated struct UserStats: Codable, Sendable {
    var workoutsCount: Int
    var streakDays: Int
    var totalVolumeKg: Double   // converted to display unit by ViewModel
    var prCount: Int
}

nonisolated struct ExercisePR: Codable, Equatable, Identifiable, Sendable {
    var id: String { normalizedName }
    let normalizedName: String
    let displayName: String
    let maxWeight: Double
    let weightUnit: WeightUnit
    let achievedAt: Date

    /// `maxWeight` normalized to kilograms so PRs can be compared/sorted
    /// consistently regardless of the unit each set was recorded in.
    var maxWeightKg: Double { maxWeight * weightUnit.toKilogramsFactor }
}

// MARK: - User Preferences
nonisolated struct UserPreferences: Codable, Sendable {
    var notificationsEnabled: Bool
    /// Legacy: the app's appearance is owned by `ThemeManager`
    /// (`AppearanceMode`, UserDefaults) since it gained "follow system".
    /// Kept so the persisted local snapshot and the cloud merge rules keep
    /// decoding unchanged; device-local, never synced to the cloud.
    var darkModeEnabled: Bool
    var weightUnit: WeightUnit
    var timezone: String          // IANA timezone, e.g. "Asia/Shanghai"
    var language: AppLanguage

    /// The single definition of "a user who has never configured anything".
    /// Both the local seed state and the cloud pull's missing-row fallback
    /// build on this, so the two can't drift apart (Issue #35).
    static func defaults(timezone: String = TimeZone.current.identifier) -> UserPreferences {
        UserPreferences(
            notificationsEnabled: true,
            darkModeEnabled: true,
            weightUnit: .kg,
            timezone: timezone,
            language: .english
        )
    }
}

// MARK: - Membership Level
nonisolated enum MembershipLevel: String, Codable, Sendable {
    case free
    case premium
    case pro

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "free":
            self = .free
        case "premium", "premium member":
            self = .premium
        case "pro", "pro member":
            self = .pro
        default:
            self = .free
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var localizedDisplayName: String {
        switch self {
        case .free:
            return String(localized: "profile.membership.free")
        case .premium:
            return String(localized: "profile.membership.premium")
        case .pro:
            return String(localized: "profile.membership.pro")
        }
    }
}

// MARK: - User Profile
nonisolated struct UserProfile: Identifiable, Codable, Sendable {
    let id: String
    var displayName: String
    var avatarURL: URL?
    var membershipLevel: MembershipLevel
    var stats: UserStats
    var preferences: UserPreferences
    var fitnessGoalSummary: String?
    var exercisePRs: [ExercisePR] = []
}
