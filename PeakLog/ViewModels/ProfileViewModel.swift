import Foundation
import Combine

@MainActor
final class ProfileViewModel: ObservableObject {
    // MARK: - State
    @Published var profile: UserProfile?
    @Published var goalSpec: GoalSpec?
    @Published var isLoading: Bool = false
    @Published var isSaving: Bool = false
    @Published var errorMessage: String?
    private let profileService: ProfileServiceProtocol

    init(profileService: ProfileServiceProtocol) {
        self.profileService = profileService
    }

    convenience init() {
        self.init(profileService: AppServices.profileService)
    }

    // MARK: - Load
    func loadProfile() async {
        isLoading = true
        errorMessage = nil
        do {
            profile = try await profileService.fetchProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadGoalSpec() async {
        goalSpec = try? await profileService.fetchGoalSpec()
    }

    @discardableResult
    func saveGoalSpec(_ spec: GoalSpec) async throws -> GoalSpec {
        isSaving = true
        defer { isSaving = false }
        let saved = try await profileService.updateGoalSpec(spec)
        goalSpec = saved
        return saved
    }

    // MARK: - Preferences

    func toggleNotifications() async {
        guard let current = profile?.preferences.notificationsEnabled else { return }
        await updatePreferences(UpdatePreferencesRequest(
            notificationsEnabled: !current,
            darkModeEnabled: nil,
            weightUnit: nil,
            timezone: nil,
            language: nil
        ))
    }

    func toggleDarkMode() async {
        guard let current = profile?.preferences.darkModeEnabled else { return }
        await updatePreferences(UpdatePreferencesRequest(
            notificationsEnabled: nil,
            darkModeEnabled: !current,
            weightUnit: nil,
            timezone: nil,
            language: nil
        ))
    }

    func setWeightUnit(_ unit: WeightUnit) async {
        await updatePreferences(UpdatePreferencesRequest(
            notificationsEnabled: nil,
            darkModeEnabled: nil,
            weightUnit: unit,
            timezone: nil,
            language: nil
        ))
    }

    func setLanguage(_ language: AppLanguage) async {
        await updatePreferences(UpdatePreferencesRequest(
            notificationsEnabled: nil,
            darkModeEnabled: nil,
            weightUnit: nil,
            timezone: nil,
            language: language
        ))
    }

    private func updatePreferences(_ request: UpdatePreferencesRequest) async {
        isSaving = true
        do {
            let updated = try await profileService.updatePreferences(request)
            profile?.preferences = updated
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
    // MARK: - Display Helpers
    var volumeDisplay: String {
        guard let stats = profile?.stats else { return "—" }
        let kg = stats.totalVolumeKg
        if kg >= 1000 {
            return String(format: "%.0ft", kg / 1000)
        }
        return String(format: "%.0fkg", kg)
    }

    var sortedExercisePRs: [ExercisePR] {
        (profile?.exercisePRs ?? []).sorted {
            if $0.maxWeight == $1.maxWeight {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.maxWeight > $1.maxWeight
        }
    }
}
