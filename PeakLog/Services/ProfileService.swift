import Foundation

// MARK: - Request DTOs

struct UpdatePreferencesRequest: Encodable {
    let notificationsEnabled: Bool?
    let darkModeEnabled: Bool?
    let weightUnit: WeightUnit?
    let timezone: String?
    let language: AppLanguage?
}

// MARK: - Protocol

/// All user profile and preferences operations.
/// Implement `LiveProfileService` to connect to the real backend.
protocol ProfileServiceProtocol {
    /// Fetch the current user's profile (stats + preferences).
    func fetchProfile() async throws -> UserProfile

    /// Update one or more preference fields.
    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences

    /// Sign the current user out (invalidate session token on server).
    func signOut() async throws
}

// MARK: - Live Implementation Stub

final class LiveProfileService: ProfileServiceProtocol {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchProfile() async throws -> UserProfile {
        // TODO: GET /profile/me
        let req = try client.request(path: "profile/me")
        return try await client.execute(req)
    }

    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences {
        // TODO: PATCH /profile/me/preferences
        let req = try client.request(method: "PATCH", path: "profile/me/preferences", body: prefs)
        return try await client.execute(req)
    }

    func signOut() async throws {
        // TODO: POST /auth/sign-out  (invalidate JWT refresh token)
        struct Empty: Decodable {}
        let req = try client.request(method: "POST", path: "auth/sign-out")
        let _: Empty = try await client.execute(req)
    }
}

// MARK: - Mock Implementation

final class MockProfileService: ProfileServiceProtocol {
    private(set) var profile = UserProfile(
        id: "user-1",
        displayName: "Sarah Chen",
        avatarURL: URL(string: "https://i.pravatar.cc/150?img=47"),
        membershipLevel: .premium,
        stats: UserStats(workoutsCount: 47, streakDays: 12, totalVolumeKg: 24000, prCount: 8),
        preferences: UserPreferences(
            notificationsEnabled: true,
            darkModeEnabled: true,
            weightUnit: .kg,
            timezone: TimeZone.current.identifier,
            language: .english
        )
    )

    func fetchProfile() async throws -> UserProfile {
        try await Task.sleep(nanoseconds: 300_000_000)
        return profile
    }

    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences {
        try await Task.sleep(nanoseconds: 200_000_000)
        if let v = prefs.notificationsEnabled { profile.preferences.notificationsEnabled = v }
        if let v = prefs.darkModeEnabled { profile.preferences.darkModeEnabled = v }
        if let v = prefs.weightUnit { profile.preferences.weightUnit = v }
        if let v = prefs.timezone { profile.preferences.timezone = v }
        if let v = prefs.language { profile.preferences.language = v }
        return profile.preferences
    }

    func signOut() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }
}
