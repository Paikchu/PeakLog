import SwiftUI

struct ProfileScreen: View {
    @StateObject private var viewModel: ProfileViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject private var localizationManager: LocalizationManager
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingWeightUnitPicker = false
    @State private var showingAppearancePicker = false
    @State private var showingGoalSpecEditor = false
    @State private var showingHelp = false
    @State private var showingPrivacy = false
    // Local optimistic mirror for the notifications toggle. SwiftUI's Toggle
    // needs the Binding's `get` to reflect the new value the instant the
    // user taps, but the real source of truth (`viewModel.profile?.preferences`)
    // only updates after the async save round-trips. Mirroring it locally lets
    // the switch flip immediately; `onChange` below resyncs the mirror
    // whenever the real preference changes (successful save, load, or a
    // change from elsewhere), and the toggle `set` closure rolls the mirror
    // back if a save fails.
    @State private var notificationsOptimistic = false

    init() {
        _viewModel = StateObject(
            wrappedValue: ProfileViewModel()
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header 随信息流上滑收起，回到顶部时复位，把滚动后的空间让给内容。
                header
                if viewModel.profile == nil && !viewModel.isLoading && viewModel.errorMessage != nil {
                    emptyState
                        .padding(.bottom, 40)
                } else {
                    VStack(spacing: 24) {
                        avatarSection
                        goalSection
                        statsSection
                        prSection
                        preferencesSection
                        supportSection
                        mediaCredit
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        // This screen is presented as a sheet, and a sheet does not follow
        // changes to the app root's override — and the appearance control
        // lives right here, so without this the screen keeps rendering in the
        // old scheme while the rest of the app switches under it.
        .appAppearance()
        .task {
            await viewModel.loadProfile()
            await viewModel.loadGoalSpec()
        }
        .onChange(of: viewModel.profile?.preferences.notificationsEnabled, initial: true) { _, newValue in
            if let newValue {
                notificationsOptimistic = newValue
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
            .appAppearance()
        }
        .sheet(isPresented: $showingHelp) {
            ProfileInfoSheet(
                titleKey: "profile.support.help",
                bodyKey: "profile.support.help.body"
            )
            .appAppearance()
        }
        .sheet(isPresented: $showingPrivacy) {
            ProfileInfoSheet(
                titleKey: "profile.support.privacy",
                bodyKey: "profile.support.privacy.body"
            )
            .appAppearance()
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
                                .appFont(size: 15, weight: .semibold)
                                .foregroundColor(.textPrimary)
                            Text(pr.achievedAt, style: .date)
                                .appFont(size: 12)
                                .foregroundColor(.textMuted)
                        }

                        Spacer()

                        Text("\(formatPRWeight(pr.maxWeight)) \(pr.weightUnit.display)")
                            .appFont(size: 14, weight: .bold)
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
        HStack(spacing: 14) {
            if viewModel.isLoading {
                // Skeleton fill must contrast with the enclosing appSurface
                // card in BOTH themes: appSurface would vanish into the card,
                // and appBackground is darker than the card in dark mode.
                Circle()
                    .fill(Color.appSeparator)
                    .frame(width: 52, height: 52)
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
                            .appFont(size: 40)
                            .foregroundColor(.textMuted)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.accentBorder.opacity(0.5), lineWidth: 2))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.profile?.displayName ?? String(localized: "common.placeholder"))
                    .appFont(size: 17, weight: .bold)
                    .foregroundColor(.textPrimary)

                Text(viewModel.profile?.membershipLevel.localizedDisplayName ?? "")
                    .appFont(size: 13)
                    .foregroundColor(.textMuted)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.appSeparator, lineWidth: 0.5)
        )
        .shadow(
            color: colorScheme == .light ? Color.black.opacity(0.06) : .clear,
            radius: 3, x: 0, y: 1
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

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
                        get: { notificationsOptimistic },
                        set: { newValue in
                            let previous = notificationsOptimistic
                            notificationsOptimistic = newValue
                            Task {
                                await viewModel.toggleNotifications()
                                // If the save didn't actually land on the value we
                                // optimistically showed (failure, or a race with
                                // another update), roll the switch back.
                                if viewModel.profile?.preferences.notificationsEnabled != newValue {
                                    notificationsOptimistic = previous
                                }
                            }
                        }
                    ),
                    isLoading: viewModel.isSaving
                )

                Divider()
                    .background(Color.appSeparator)
                    .padding(.horizontal, 16)

                // Appearance is device-local and owned by ThemeManager
                // (UserDefaults): it applies synchronously, so there is no
                // async save to mirror optimistically or roll back.
                PreferenceNavRow(
                    icon: "circle.lefthalf.filled",
                    title: "profile.preferences.appearance",
                    detail: themeManager.mode.localizedDisplayName
                ) {
                    showingAppearancePicker = true
                }
                .confirmationDialog(
                    "profile.preferences.appearance.choose",
                    isPresented: $showingAppearancePicker,
                    titleVisibility: .visible
                ) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button(mode.localizedDisplayName) {
                            themeManager.mode = mode
                        }
                    }
                }
            }
        }
    }

    // MARK: - Support
    private var supportSection: some View {
        SettingsSection(title: "profile.section.support") {
            PreferenceNavRow(icon: "questionmark.circle", title: "profile.support.help") {
                showingHelp = true
            }

            Divider()
                .background(Color.appSeparator)
                .padding(.horizontal, 16)

            PreferenceNavRow(icon: "doc.text", title: "profile.support.privacy") {
                showingPrivacy = true
            }
        }
    }

    /// The bundled exercise demonstrations are licensed media, not ours; the
    /// rights holder requires the credit to travel with them.
    private var mediaCredit: some View {
        Text("settings.media_credit")
            .appFont(size: 11)
            .foregroundColor(.textDarkMuted)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
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

    // Shown when the profile failed to load (or is empty) and we're not
    // mid-flight. Gives the user a retry affordance instead of silent placeholders.
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .appFont(size: 40)
                .foregroundColor(.textMuted)

            Text("profile.empty.title")
                .appFont(size: 16, weight: .semibold)
                .foregroundColor(.textPrimary)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .appFont(size: 13)
                    .foregroundColor(.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button("profile.empty.retry") {
                Task { await viewModel.loadProfile() }
            }
            .appFont(size: 14, weight: .semibold)
            .foregroundColor(Color.accentPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// Minimal in-app info sheet used by the Profile support rows (Help / Privacy).
/// Replace the placeholder body copy with the finalized FAQ / policy text or a
/// deep link once those resources are available.
private struct ProfileInfoSheet: View {
    let titleKey: String
    let bodyKey: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(String(localized: String.LocalizationValue(bodyKey)))
                    .appFont(size: 15)
                    .foregroundColor(.textSecondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(String(localized: String.LocalizationValue(titleKey)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.ok") { dismiss() }
                }
            }
        }
    }
}

#Preview("Dark") {
    ProfileScreen()
        .environmentObject(previewThemeManager(.dark))
        .environmentObject(LocalizationManager())
}

#Preview("Light") {
    ProfileScreen()
        .environmentObject(previewThemeManager(.light))
        .environmentObject(LocalizationManager())
}

@MainActor
private func previewThemeManager(_ mode: AppearanceMode) -> ThemeManager {
    // A throwaway suite keeps previews from writing over the real choice.
    let manager = ThemeManager(defaults: UserDefaults(suiteName: "peaklog.preview") ?? .standard)
    manager.mode = mode
    return manager
}
