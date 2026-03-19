import Foundation

// MARK: - User Stats
struct UserStats: Codable {
    var workoutsCount: Int
    var streakDays: Int
    var totalVolumeKg: Double   // converted to display unit by ViewModel
    var prCount: Int
}

struct ExercisePR: Codable, Equatable, Identifiable {
    var id: String { normalizedName }
    let normalizedName: String
    let displayName: String
    let maxWeight: Double
    let weightUnit: WeightUnit
    let achievedAt: Date
}

// MARK: - User Preferences
struct UserPreferences: Codable {
    var notificationsEnabled: Bool
    var darkModeEnabled: Bool
    var weightUnit: WeightUnit
    var timezone: String          // IANA timezone, e.g. "Asia/Shanghai"
    var language: AppLanguage
}

// MARK: - Membership Level
enum MembershipLevel: String, Codable {
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
struct UserProfile: Identifiable, Codable {
    let id: String
    var displayName: String
    var avatarURL: URL?
    var membershipLevel: MembershipLevel
    var stats: UserStats
    var preferences: UserPreferences
    var exercisePRs: [ExercisePR] = []
}
