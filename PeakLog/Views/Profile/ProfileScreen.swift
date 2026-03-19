import SwiftUI

struct ProfileScreen: View {
    @StateObject private var viewModel: ProfileViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject private var localizationManager: LocalizationManager
    @Environment(\.openURL) private var openURL
    var onBack: (() -> Void)?
    var onSignOut: (() -> Void)?

    init(onBack: (() -> Void)? = nil, onSignOut: (() -> Void)? = nil) {
        _viewModel = StateObject(
            wrappedValue: ProfileViewModel(profileService: SupabaseProfileService())
        )
        self.onBack = onBack
        self.onSignOut = onSignOut
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 24) {
                    avatarSection
                    statsSection
                    preferencesSection
                    supportSection
                    signOutButton
                }
                .padding(.bottom, 40)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .task {
            await viewModel.loadProfile()
            if let preferences = viewModel.profile?.preferences {
                themeManager.isDarkMode = preferences.darkModeEnabled
            }
        }
        .alert("common.error_title", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Header
    private var header: some View {
        HStack {
            Button {
                onBack?()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .frame(width: 38, height: 38)
            }

            Spacer()

            Text("profile.title")
                .font(.screenTitle)
                .foregroundColor(.textPrimary)

            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Avatar
    private var avatarSection: some View {
        VStack(spacing: 8) {
            if viewModel.isLoading {
                Circle()
                    .fill(Color.appSurface)
                    .frame(width: 80, height: 80)
                    .overlay(ProgressView())
            } else {
                AsyncImage(url: viewModel.profile?.avatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.textMuted)
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.accentBorder.opacity(0.5), lineWidth: 2))
            }

            Text(viewModel.profile?.displayName ?? String(localized: "common.placeholder"))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.textPrimary)

            Text(viewModel.profile?.membershipLevel.localizedDisplayName ?? "")
                .font(.system(size: 13))
                .foregroundColor(.textMuted)
        }
        .padding(.top, 16)
    }

    // MARK: - Stats
    private var statsSection: some View {
        HStack(spacing: 8) {
            StatCardView(
                icon: "trophy.fill",
                iconColor: .accentPurple,
                value: "\(viewModel.profile?.stats.workoutsCount ?? 0)",
                label: "profile.stats.workouts"
            )
            StatCardView(
                icon: "flame.fill",
                iconColor: .orange,
                value: "\(viewModel.profile?.stats.streakDays ?? 0)d",
                label: "profile.stats.streak"
            )
            StatCardView(
                icon: "chart.line.uptrend.xyaxis",
                iconColor: .green,
                value: viewModel.volumeDisplay,
                label: "profile.stats.volume"
            )
            StatCardView(
                icon: "star.fill",
                iconColor: Color(hex: "#F59E0B"),
                value: "\(viewModel.profile?.stats.prCount ?? 0)",
                label: "profile.stats.prs"
            )
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Preferences
    @ViewBuilder
    private var preferencesSection: some View {
        if let prefs = viewModel.profile?.preferences {
            SettingsSection(title: "profile.section.preferences") {
                PreferenceNavRow(
                    icon: "globe",
                    title: "profile.preferences.language",
                    detail: localizationManager.appLanguage.nativeDisplayName
                ) {
                    openAppSettings()
                }

                Divider()
                    .background(Color.appSeparator)
                    .padding(.horizontal, 16)

                PreferenceToggleRow(
                    icon: "bell",
                    title: "profile.preferences.notifications",
                    isOn: Binding(
                        get: { prefs.notificationsEnabled },
                        set: { _ in Task { await viewModel.toggleNotifications() } }
                    ),
                    isLoading: viewModel.isSaving
                )

                Divider()
                    .background(Color.appSeparator)
                    .padding(.horizontal, 16)

                PreferenceToggleRow(
                    icon: "moon",
                    title: "profile.preferences.dark_mode",
                    isOn: Binding(
                        get: { prefs.darkModeEnabled },
                        set: { newValue in
                            themeManager.isDarkMode = newValue
                            Task { await viewModel.toggleDarkMode() }
                        }
                    ),
                    isLoading: viewModel.isSaving
                )
            }
        }
    }

    // MARK: - Support
    private var supportSection: some View {
        SettingsSection(title: "profile.section.support") {
            PreferenceNavRow(icon: "questionmark.circle", title: "profile.support.help") {
                // TODO: Open Help & FAQ
            }

            Divider()
                .background(Color.appSeparator)
                .padding(.horizontal, 16)

            PreferenceNavRow(icon: "doc.text", title: "profile.support.privacy") {
                // TODO: Open Privacy Policy URL
            }
        }
    }

    // MARK: - Sign Out
    private var signOutButton: some View {
        Button {
            Task {
                await viewModel.signOut()
                onSignOut?()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 15))
                Text("profile.sign_out")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.accentRed)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.appSurface)
            .cornerRadius(AppRadius.xl)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .strokeBorder(Color.accentRed.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }
}

#Preview("Dark") {
    ProfileScreen()
        .environmentObject(ThemeManager())
        .environmentObject(AuthStateManager())
}

#Preview("Light") {
    ProfileScreen()
        .environmentObject({ let t = ThemeManager(); t.isDarkMode = false; return t }())
}
