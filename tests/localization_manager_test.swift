import Foundation

@main
struct LocalizationManagerTestRunner {
    static func main() async {
        appLanguageMapsSupportedIdentifiers()
        await localizationManagerUsesSystemLanguageOnInit()
        await localizationManagerRefreshesWhenSystemLanguageChanges()
        await profileViewModelUpdatesLanguagePreference()
        print("localization_manager_test passed")
    }

    private static func appLanguageMapsSupportedIdentifiers() {
        precondition(AppLanguage.bestMatch(for: ["zh-Hans-CN"]) == .simplifiedChinese)
        precondition(AppLanguage.bestMatch(for: ["en-US"]) == .english)
        precondition(AppLanguage.bestMatch(for: ["fr-FR"]) == .english)
    }

    @MainActor
    private static func localizationManagerUsesSystemLanguageOnInit() async {
        let manager = LocalizationManager(
            preferredLanguages: { ["zh-Hans-CN"] }
        )

        precondition(manager.appLanguage == .simplifiedChinese)
        precondition(manager.locale.identifier == AppLanguage.simplifiedChinese.localeIdentifier)
    }

    @MainActor
    private static func localizationManagerRefreshesWhenSystemLanguageChanges() async {
        let preferredLanguageSource = PreferredLanguageSource(values: ["en-US"])

        let manager = LocalizationManager(
            preferredLanguages: { preferredLanguageSource.values }
        )

        precondition(manager.appLanguage == .english)

        preferredLanguageSource.values = ["zh-Hans"]
        manager.refreshFromSystem()

        precondition(manager.appLanguage == .simplifiedChinese)
    }

    @MainActor
    private static func profileViewModelUpdatesLanguagePreference() async {
        let service = RecordingProfileService()
        let viewModel = ProfileViewModel(profileService: service)

        await viewModel.loadProfile()
        await viewModel.setLanguage(.simplifiedChinese)

        let lastUpdatedRequest = await service.lastUpdatedRequest
        precondition(lastUpdatedRequest?.language == .simplifiedChinese)
        precondition(viewModel.profile?.preferences.language == .simplifiedChinese)
    }
}

private final class PreferredLanguageSource {
    var values: [String]

    init(values: [String]) {
        self.values = values
    }
}

private actor RecordingProfileService: ProfileServiceProtocol {
    private(set) var lastUpdatedRequest: UpdatePreferencesRequest?

    func fetchProfile() async throws -> UserProfile {
        UserProfile(
            id: "user-1",
            displayName: "Test User",
            avatarURL: nil,
            membershipLevel: .premium,
            stats: UserStats(workoutsCount: 1, streakDays: 2, totalVolumeKg: 3, prCount: 4),
            preferences: UserPreferences(
                notificationsEnabled: true,
                weightUnit: .kg,
                timezone: "Asia/Shanghai",
                language: .english
            ),
            fitnessGoalSummary: nil
        )
    }

    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences {
        lastUpdatedRequest = prefs
        return UserPreferences(
            notificationsEnabled: true,
            weightUnit: .kg,
            timezone: "Asia/Shanghai",
            language: prefs.language ?? .english
        )
    }

    func signOut() async throws {}

    func updateFitnessGoalSummary(_ summary: String) async throws -> String {
        summary
    }

    func fetchGoalSpec() async throws -> GoalSpec? {
        nil
    }

    func updateGoalSpec(_ spec: GoalSpec) async throws -> GoalSpec {
        spec
    }
}
