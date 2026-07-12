import SwiftUI

struct ProfileScreen: View {
    @StateObject private var viewModel: ProfileViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject private var localizationManager: LocalizationManager
    @EnvironmentObject private var authManager: AuthStateManager
    @EnvironmentObject private var syncController: CloudSyncController
    @Environment(\.openURL) private var openURL
    @State private var showingWeightUnitPicker = false
    @State private var showingGoalSpecEditor = false

    init() {
        _viewModel = StateObject(
            wrappedValue: ProfileViewModel()
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 24) {
                    avatarSection
                    syncStatusRow
                    goalSection
                    statsSection
                    prSection
                    preferencesSection
                    supportSection
                }
                .padding(.bottom, 40)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .task {
            await viewModel.loadProfile()
            await viewModel.loadGoalSpec()
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
        .sheet(isPresented: $showingGoalSpecEditor) {
            GoalSpecEditorScreen(
                initial: viewModel.goalSpec,
                legacyGoalSummary: viewModel.profile?.fitnessGoalSummary
            ) { spec in
                try await viewModel.saveGoalSpec(spec)
            }
        }
    }

    @ViewBuilder
    private var prSection: some View {
        let prs = viewModel.sortedExercisePRs
        if !prs.isEmpty {
            SettingsSection(title: "PRs") {
                ForEach(Array(prs.enumerated()), id: \.element.id) { index, pr in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pr.displayName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.textPrimary)
                            Text(pr.achievedAt, style: .date)
                                .font(.system(size: 12))
                                .foregroundColor(.textMuted)
                        }

                        Spacer()

                        Text("\(formatPRWeight(pr.maxWeight)) \(pr.weightUnit.display)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Color.accentValue)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if index < prs.count - 1 {
                        Divider()
                            .background(Color.appSeparator)
                            .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    // MARK: - Header
    private var header: some View {
        RootPageHeader(title: String(localized: "profile.title"))
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

    // MARK: - Cloud sync status
    // Hidden outside a signed-in cloud session (DEBUG local mode has nothing
    // to report). The write path is local-first — a mutation's UI update
    // never waits on the network — so without this, a background push
    // failure (e.g. offline) would be invisible and a user could go days
    // without realizing their training data wasn't backed up.
    @ViewBuilder
    private var syncStatusRow: some View {
        if case .signedIn = authManager.state {
            HStack(spacing: 6) {
                syncStatusIcon
                Text(syncStatusText)
                    .font(.system(size: 12))
                    .foregroundColor(.textMuted)
            }
        }
    }

    @ViewBuilder
    private var syncStatusIcon: some View {
        switch syncController.syncStatus {
        case .idle:
            Image(systemName: "checkmark.icloud")
                .foregroundColor(.textMuted)
        case .syncing:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
        case .pendingRetry:
            Image(systemName: "exclamationmark.icloud")
                .foregroundColor(Color.accentValue)
        }
    }

    private var syncStatusText: LocalizedStringKey {
        switch syncController.syncStatus {
        case .idle: return "profile.sync.idle"
        case .syncing: return "profile.sync.syncing"
        case .pendingRetry: return "profile.sync.pending_retry"
        }
    }

    @ViewBuilder
    private var goalSection: some View {
        SettingsSection(title: "goal_spec.section.goal") {
            PreferenceNavRow(
                icon: "target",
                title: "profile.goal_spec.entry",
                detail: viewModel.goalSpec?.objective.displayLabel
            ) {
                showingGoalSpecEditor = true
            }
        }
        .padding(.horizontal, 16)

        if let goal = viewModel.profile?.fitnessGoalSummary, !goal.isEmpty {
            SettingsSection(title: "Fitness Goal") {
                Text(goal)
                    .font(.system(size: 14))
                    .foregroundColor(.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Stats
    private var statsSection: some View {
        HStack(spacing: 8) {
            StatCardView(
                icon: "trophy.fill",
                iconColor: .accentPrimary,
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
                iconColor: Color.accentValue,
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

                PreferenceNavRow(
                    icon: "scalemass",
                    title: "profile.preferences.weight_unit",
                    detail: prefs.weightUnit.display
                ) {
                    showingWeightUnitPicker = true
                }
                .confirmationDialog(
                    "profile.preferences.weight_unit.choose",
                    isPresented: $showingWeightUnitPicker,
                    titleVisibility: .visible
                ) {
                    ForEach(WeightUnit.allCases, id: \.self) { unit in
                        Button(unit.display) {
                            Task { await viewModel.setWeightUnit(unit) }
                        }
                    }
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

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }

    private func formatPRWeight(_ weight: Double) -> String {
        if weight.rounded() == weight {
            return String(format: "%.0f", weight)
        }
        return String(format: "%.1f", weight)
    }
}

#Preview("Dark") {
    ProfileScreen()
        .environmentObject(ThemeManager())
        .environmentObject(LocalizationManager())
}

#Preview("Light") {
    ProfileScreen()
        .environmentObject({ let t = ThemeManager(); t.isDarkMode = false; return t }())
        .environmentObject(LocalizationManager())
}
