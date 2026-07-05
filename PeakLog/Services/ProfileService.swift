import Foundation

struct UpdatePreferencesRequest: Encodable {
    let notificationsEnabled: Bool?
    let darkModeEnabled: Bool?
    let weightUnit: WeightUnit?
    let timezone: String?
    let language: AppLanguage?
}

protocol ProfileServiceProtocol {
    func fetchProfile() async throws -> UserProfile
    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences
    func updateFitnessGoalSummary(_ summary: String) async throws -> String
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
}

final class MockProfileService: ProfileServiceProtocol {
    private let local = LocalProfileService(database: .shared)

    func fetchProfile() async throws -> UserProfile {
        try await local.fetchProfile()
    }

    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences {
        try await local.updatePreferences(prefs)
    }

    func updateFitnessGoalSummary(_ summary: String) async throws -> String {
        try await local.updateFitnessGoalSummary(summary)
    }
}
