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
            let language: String?
            enum CodingKeys: String, CodingKey {
                case notificationsEnabled = "notifications_enabled"
                case darkModeEnabled = "dark_mode_enabled"
                case weightUnit = "weight_unit"
                case timezone
                case language
            }
        }

        struct ExercisePRRow: Decodable {
            let normalizedName: String
            let displayName: String
            let maxWeight: Double
            let weightUnit: String
            let achievedAt: Date

            enum CodingKeys: String, CodingKey {
                case normalizedName = "normalized_name"
                case displayName = "display_name"
                case maxWeight = "max_weight"
                case weightUnit = "weight_unit"
                case achievedAt = "achieved_at"
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

        async let exercisePRsFetch: [ExercisePRRow] = supabase
            .from("profile_exercise_prs")
            .select()
            .eq("user_id", value: uid)
            .order("max_weight", ascending: false)
            .execute()
            .value

        let (profile, stats, prefs, exercisePRs) = try await (profileFetch, statsFetch, prefsFetch, exercisePRsFetch)

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
                timezone: prefs.timezone ?? TimeZone.current.identifier,
                language: AppLanguage.resolve(prefs.language) ?? .english
            ),
            exercisePRs: exercisePRs.map {
                ExercisePR(
                    normalizedName: $0.normalizedName,
                    displayName: $0.displayName,
                    maxWeight: $0.maxWeight,
                    weightUnit: WeightUnit(rawValue: $0.weightUnit) ?? .kg,
                    achievedAt: $0.achievedAt
                )
            }
        )
    }

    // MARK: - Update preferences

    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences {
        let user = try await supabase.auth.session.user
        let uid = user.id.uuidString

        var updateFields: [String: AnyJSON] = [:]
        if let v = prefs.notificationsEnabled { updateFields["notifications_enabled"] = .bool(v) }
        if let v = prefs.darkModeEnabled      { updateFields["dark_mode_enabled"] = .bool(v) }
        if let v = prefs.weightUnit           { updateFields["weight_unit"] = .string(v.rawValue) }
        if let v = prefs.timezone             { updateFields["timezone"] = .string(v) }
        if let v = prefs.language             { updateFields["language"] = .string(v.rawValue) }

        guard !updateFields.isEmpty else {
            return try await fetchProfile().preferences
        }

        struct PrefsRow: Decodable {
            let notificationsEnabled: Bool
            let darkModeEnabled: Bool
            let weightUnit: String
            let timezone: String?
            let language: String?
            enum CodingKeys: String, CodingKey {
                case notificationsEnabled = "notifications_enabled"
                case darkModeEnabled = "dark_mode_enabled"
                case weightUnit = "weight_unit"
                case timezone
                case language
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
            timezone: row.timezone ?? TimeZone.current.identifier,
            language: AppLanguage.resolve(row.language) ?? .english
        )
    }

    // MARK: - Sign out

    func signOut() async throws {
        try await supabase.auth.signOut()
    }
}
