import Foundation
import Supabase

// MARK: - SupabaseProfileService

final class SupabaseProfileService: ProfileServiceProtocol {
    private let supabase = SupabaseManager.shared.client

    // MARK: - Fetch profile

    func fetchProfile() async throws -> UserProfile {
        let user = try await supabase.auth.session.user
        let uid = user.id.uuidString

        struct ProfileRow: Decodable {
            let id: String
            let displayName: String
            let avatarUrl: String?
            let membershipType: String
            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
                case avatarUrl = "avatar_url"
                case membershipType = "membership_type"
            }
        }

        struct StatsRow: Decodable {
            let workoutsCount: Int
            let streakDays: Int
            let totalVolume: Double
            let prCount: Int
            enum CodingKeys: String, CodingKey {
                case workoutsCount = "workouts_count"
                case streakDays = "streak_days"
                case totalVolume = "total_volume"
                case prCount = "pr_count"
            }
        }

        struct PrefsRow: Decodable {
            let notificationsEnabled: Bool
            let darkModeEnabled: Bool
            let weightUnit: String
            let timezone: String?
            enum CodingKeys: String, CodingKey {
                case notificationsEnabled = "notifications_enabled"
                case darkModeEnabled = "dark_mode_enabled"
                case weightUnit = "weight_unit"
                case timezone
            }
        }

        async let profileFetch: ProfileRow = supabase
            .from("profiles")
            .select()
            .eq("id", value: uid)
            .single()
            .execute()
            .value

        async let statsFetch: StatsRow = supabase
            .from("user_stats")
            .select()
            .eq("user_id", value: uid)
            .single()
            .execute()
            .value

        async let prefsFetch: PrefsRow = supabase
            .from("user_preferences")
            .select()
            .eq("user_id", value: uid)
            .single()
            .execute()
            .value

        let (profile, stats, prefs) = try await (profileFetch, statsFetch, prefsFetch)

        return UserProfile(
            id: profile.id,
            displayName: profile.displayName,
            avatarURL: profile.avatarUrl.flatMap { URL(string: $0) },
            membershipLevel: MembershipLevel(rawValue: profile.membershipType) ?? .free,
            stats: UserStats(
                workoutsCount: stats.workoutsCount,
                streakDays: stats.streakDays,
                totalVolumeKg: stats.totalVolume,
                prCount: stats.prCount
            ),
            preferences: UserPreferences(
                notificationsEnabled: prefs.notificationsEnabled,
                darkModeEnabled: prefs.darkModeEnabled,
                weightUnit: WeightUnit(rawValue: prefs.weightUnit) ?? .kg,
                timezone: prefs.timezone ?? TimeZone.current.identifier
            )
        )
    }

    // MARK: - Update preferences

    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences {
        let user = try await supabase.auth.session.user
        let uid = user.id.uuidString

        var updateFields: [String: AnyJSON] = [:]
        if let v = prefs.notificationsEnabled { updateFields["notifications_enabled"] = AnyJSON(v) }
        if let v = prefs.darkModeEnabled      { updateFields["dark_mode_enabled"] = AnyJSON(v) }
        if let v = prefs.weightUnit           { updateFields["weight_unit"] = AnyJSON(v.rawValue) }
        if let v = prefs.timezone             { updateFields["timezone"] = AnyJSON(v) }

        guard !updateFields.isEmpty else {
            return try await fetchProfile().preferences
        }

        struct PrefsRow: Decodable {
            let notificationsEnabled: Bool
            let darkModeEnabled: Bool
            let weightUnit: String
            let timezone: String?
            enum CodingKeys: String, CodingKey {
                case notificationsEnabled = "notifications_enabled"
                case darkModeEnabled = "dark_mode_enabled"
                case weightUnit = "weight_unit"
                case timezone
            }
        }

        let rows: [PrefsRow] = try await supabase
            .from("user_preferences")
            .update(updateFields)
            .eq("user_id", value: uid)
            .select()
            .execute()
            .value

        guard let row = rows.first else { throw APIError.notFound }
        return UserPreferences(
            notificationsEnabled: row.notificationsEnabled,
            darkModeEnabled: row.darkModeEnabled,
            weightUnit: WeightUnit(rawValue: row.weightUnit) ?? .kg,
            timezone: row.timezone ?? TimeZone.current.identifier
        )
    }

    // MARK: - Sign out

    func signOut() async throws {
        try await supabase.auth.signOut()
    }
}
