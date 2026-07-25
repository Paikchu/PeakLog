import Foundation

// Logic test for Issue #35: the "never configured a profile" boundary.
//
// Contract under test (see ProfileServiceProtocol.fetchProfile):
//   1. A fresh LocalAppDatabase (first launch, no state file) serves a
//      profile carrying UserPreferences.defaults() — callers never see an
//      "empty profile".
//   2. A brand-new signup (no profiles/user_preferences rows in the cloud)
//      assembles to the same defaults via CloudMapper.profile.
//   3. Appearance is not a synced preference — it lives in ThemeManager, and
//      the vestigial server column stays out of the client's way:
//      a. the pushed PreferencesRow carries no dark_mode_enabled field;
//      b. pulling a server row that still has the column decodes fine.
//
// Compile with:
//   swiftc -parse-as-library \
//     PeakLog/Models/*.swift PeakLog/Localization/AppLanguage.swift \
//     PeakLog/Support/WorkoutDateFormatter.swift \
//     PeakLog/Services/SupabaseConfig.swift \
//     PeakLog/Services/Auth/*.swift \
//     PeakLog/Services/ProfileService.swift PeakLog/Services/WorkoutService.swift \
//     PeakLog/Services/TrainingPlanService.swift PeakLog/Services/ExerciseLibraryService.swift \
//     PeakLog/Services/ExerciseRecommendationEngine.swift PeakLog/Services/SetDefaultsProvider.swift \
//     PeakLog/Services/LocalAppDatabase.swift \
//     PeakLog/Services/Cloud/LocalDataSnapshot.swift \
//     PeakLog/Services/Cloud/CloudRows.swift PeakLog/Services/Cloud/CloudMapper.swift \
//     tests/profile_defaults_boundary_test.swift -o /tmp/pdb && /tmp/pdb

@main
struct ProfileDefaultsBoundaryTest {
    static func main() async throws {
        await testFreshDatabaseServesDefaultPreferences()
        try testBrandNewSignupAssemblesDefaults()
        try testDarkModeIsNotOnTheWire()
        print("profile_defaults_boundary_test passed")
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-profile-defaults-test-\(UUID().uuidString).json")
    }

    // 1. fetchProfile never returns an empty profile on first launch.
    static func testFreshDatabaseServesDefaultPreferences() async {
        let db = LocalAppDatabase(fileURL: tempURL())
        let profile = await db.fetchProfile()
        let defaults = UserPreferences.defaults()

        precondition(!profile.id.isEmpty, "fresh profile must have an id")
        precondition(profile.preferences.notificationsEnabled == defaults.notificationsEnabled,
            "fresh profile must carry default notificationsEnabled")
        precondition(profile.preferences.weightUnit == defaults.weightUnit,
            "fresh profile must carry default weightUnit")
        precondition(profile.preferences.language == defaults.language,
            "fresh profile must carry default language")
        precondition(profile.preferences.timezone == TimeZone.current.identifier,
            "fresh profile must carry the device timezone")
    }

    // 2. No cloud rows yet (brand-new signup) → same defaults, UTC timezone.
    static func testBrandNewSignupAssemblesDefaults() throws {
        let userId = "11111111-1111-1111-1111-111111111111"
        let profile = CloudMapper.profile(userId: userId, profileRow: nil, preferencesRow: nil)
        let defaults = UserPreferences.defaults(timezone: "UTC")

        precondition(profile.id == userId, "assembled profile must adopt the auth user id")
        precondition(profile.preferences.notificationsEnabled == defaults.notificationsEnabled,
            "signup profile must carry default notificationsEnabled")
        precondition(profile.preferences.weightUnit == defaults.weightUnit,
            "signup profile must carry default weightUnit")
        precondition(profile.preferences.language == defaults.language,
            "signup profile must carry default language")
        precondition(profile.preferences.timezone == "UTC",
            "signup profile must fall back to UTC until reconcileDeviceTimezone runs")
    }

    // 3a/3b. The client never writes dark_mode_enabled, and a server row that
    // still has the (now vestigial) column decodes fine.
    static func testDarkModeIsNotOnTheWire() throws {
        let prefs = UserPreferences.defaults(timezone: "UTC")
        let profile = UserProfile(id: "u1", displayName: "T", avatarURL: nil,
            membershipLevel: .free,
            stats: UserStats(workoutsCount: 0, streakDays: 0, totalVolumeKg: 0, prCount: 0),
            preferences: prefs, fitnessGoalSummary: nil, exercisePRs: [])

        let encoded = try JSONEncoder().encode(CloudMapper.preferencesRow(from: profile))
        let json = String(decoding: encoded, as: UTF8.self)
        precondition(!json.contains("dark_mode_enabled"),
            "push must not touch the server's dark_mode_enabled column")

        let serverJSON = Data("""
        {"user_id":"u1","notifications_enabled":true,"dark_mode_enabled":true,
         "weight_unit":"kg","language":"en"}
        """.utf8)
        let row = try JSONDecoder().decode(PreferencesRow.self, from: serverJSON)
        precondition(row.user_id == "u1", "server row with legacy column must still decode")
    }
}
