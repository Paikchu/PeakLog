import Foundation

// MARK: - User Stats
struct UserStats: Codable {
    var workoutsCount: Int
    var streakDays: Int
    var totalVolumeKg: Double   // converted to display unit by ViewModel
    var prCount: Int
}

// MARK: - User Preferences
struct UserPreferences: Codable {
    var notificationsEnabled: Bool
    var darkModeEnabled: Bool
    var weightUnit: WeightUnit
    var timezone: String          // IANA timezone, e.g. "Asia/Shanghai"
}

// MARK: - Membership Level
enum MembershipLevel: String, Codable {
    case free = "Free"
    case premium = "Premium Member"
    case pro = "Pro Member"
}

// MARK: - User Profile
struct UserProfile: Identifiable, Codable {
    let id: String
    var displayName: String
    var avatarURL: URL?
    var membershipLevel: MembershipLevel
    var stats: UserStats
    var preferences: UserPreferences
}
