import Foundation

struct UpdatePreferencesRequest: Encodable {
    let notificationsEnabled: Bool?
    let weightUnit: WeightUnit?
    let timezone: String?
    let language: AppLanguage?
}

protocol ProfileServiceProtocol {
    /// Contract: never surfaces an "empty profile". When the user has never
    /// set anything up (fresh install, brand-new signup), implementations
    /// must still return a profile whose `preferences` carry
    /// `UserPreferences.defaults` — "first-time setup" is not a state
    /// callers have to handle. `LocalAppDatabase` guarantees this by
    /// seeding on init; the cloud pull by defaulting missing rows
    /// (`CloudMapper.profile`). See Issue #35.
    func fetchProfile() async throws -> UserProfile
    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences
    func updateFitnessGoalSummary(_ summary: String) async throws -> String
    func fetchGoalSpec() async throws -> GoalSpec?
    func updateGoalSpec(_ spec: GoalSpec) async throws -> GoalSpec
}

final class LocalProfileService: ProfileServiceProtocol {
    private let database: LocalAppDatabase

    init(database: LocalAppDatabase) {
        self.database = database
    }

    func fetchProfile() async throws -> UserProfile {
        await database.fetchProfile()
    }

    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences {
        try await database.updatePreferences(prefs)
    }

    func updateFitnessGoalSummary(_ summary: String) async throws -> String {
        try await database.updateFitnessGoalSummary(summary)
    }

    func fetchGoalSpec() async throws -> GoalSpec? {
        await database.goalSpec()
    }

    func updateGoalSpec(_ spec: GoalSpec) async throws -> GoalSpec {
        try await database.updateGoalSpec(spec)
    }
}
