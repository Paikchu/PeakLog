import SwiftUI

// MARK: - Exercise Detail
// Reached from the info button on a picker row. Shows the looping
// demonstration, the numbered cues, and which muscles the movement is for —
// the "what does this actually look like" answer the flat list can't give.

struct ExerciseDetailSheet: View {
    @EnvironmentObject private var localizationManager: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    let definition: ExerciseDefinition

    @State private var detail: ExerciseDetail?
    @State private var attribution: String?
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ExerciseAnimationView(
                        mediaId: definition.mediaId,
                        muscleGroup: definition.muscleGroup
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    header
                        .padding(.horizontal, 16)
                        .padding(.top, 18)

                    tagRow
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    if !steps.isEmpty {
                        sectionLabel("exercise_detail.steps")
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            stepRow(index: index, text: step)
                        }
                    } else if hasLoaded {
                        Text("exercise_detail.no_steps")
                            .appFont(.chatBody)
                            .foregroundColor(.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    }

                    if let attribution, definition.mediaId != nil {
                        Text(attribution)
                            .appFont(size: 10, weight: .regular)
                            .foregroundColor(.textDarkMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 16)
                            .padding(.top, 28)
                    }
                }
                .padding(.bottom, 28)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle(definition.displayName(for: localizationManager.appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            // The demonstration tile is near-white, and it scrolls under the
            // bar — without an opaque background the title and Done button
            // disappear into it.
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.done")) { dismiss() }
                        .appFont(size: 15, weight: .medium)
                        .foregroundColor(.accentValue)
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(definition.displayName(for: localizationManager.appLanguage))
                .appFont(size: 20, weight: .bold)
                .foregroundColor(.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Text(secondaryName)
                .appFont(.chatBody)
                .foregroundColor(.textMuted)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }

    /// The name in the other language — useful when searching a gym machine's
    /// English label, or reading an English movement name in a Chinese UI.
    private var secondaryName: String {
        switch localizationManager.appLanguage {
        case .english: return definition.nameZH
        case .simplifiedChinese: return definition.nameEN
        }
    }

    private var tagRow: some View {
        HStack(spacing: 8) {
            tag(definition.muscleGroup.displayLabel)
            tag(definition.equipment.displayLabel)
            tag(definition.loadType.displayLabel)
            Spacer(minLength: 0)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .appFont(size: 11, weight: .medium)
            .foregroundColor(.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.workoutPanel))
    }

    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .appFont(size: 11, weight: .medium)
            .kerning(1.1)
            .foregroundColor(.textMuted)
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    private func stepRow(index: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .appFont(.setIndex)
                .foregroundColor(.accentValue)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentPrimary.opacity(0.14)))

            Text(text)
                .appFont(.chatBody)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Data

    private var steps: [String] {
        detail?.steps(for: localizationManager.appLanguage) ?? []
    }

    private func load() async {
        guard !hasLoaded else { return }
        detail = await ExerciseDetailLibrary.shared.detail(for: definition.id)
        attribution = await ExerciseDetailLibrary.shared.attribution()
        hasLoaded = true
    }
}

#Preview {
    ExerciseDetailSheet(
        definition: ExerciseDefinition(
            id: "barbell-bench-press",
            nameEN: "Bench Press",
            nameZH: "杠铃卧推",
            muscleGroup: .chest,
            equipment: .barbell,
            loadType: .weighted,
            mediaId: "0025"
        )
    )
    .environmentObject(LocalizationManager())
}
