import Combine
import Foundation

@MainActor
final class LocalizationManager: ObservableObject {
    @Published private(set) var appLanguage: AppLanguage

    var locale: Locale {
        Locale(identifier: appLanguage.localeIdentifier)
    }

    private let preferredLanguages: () -> [String]

    init(
        preferredLanguages: @escaping () -> [String] = {
            Bundle.main.preferredLocalizations + Locale.preferredLanguages
        }
    ) {
        self.preferredLanguages = preferredLanguages
        self.appLanguage = AppLanguage.bestMatch(for: preferredLanguages())
    }

    func refreshFromSystem() {
        let resolved = AppLanguage.bestMatch(for: preferredLanguages())
        guard resolved != appLanguage else { return }
        appLanguage = resolved
    }

    func syncRemotePreferenceIfNeeded(profileService: ProfileServiceProtocol) async {
        do {
            let profile = try await profileService.fetchProfile()
            guard profile.preferences.language != appLanguage else { return }

            _ = try await profileService.updatePreferences(
                UpdatePreferencesRequest(
                    notificationsEnabled: nil,
                    darkModeEnabled: nil,
                    weightUnit: nil,
                    timezone: nil,
                    language: appLanguage
                )
            )
        } catch {
            // Keep the UI bound to the system language even if preference sync fails.
        }
    }
}
