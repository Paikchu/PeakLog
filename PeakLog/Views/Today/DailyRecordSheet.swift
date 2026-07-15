import SwiftUI

enum DailyRecordDraft: Equatable {
    case strength(StrengthSessionDraft)
    case cardio(CardioMetrics)
}

private enum DailyRecordMode: String, CaseIterable, Identifiable {
    case strength
    case cardio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strength:
            return String(localized: "daily_record.type.strength")
        case .cardio:
            return String(localized: "daily_record.type.cardio")
        }
    }
}

struct DailyRecordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localizationManager: LocalizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Route: Hashable {
        case picker
    }

    @State private var mode: DailyRecordMode = .strength
    @State private var title = ""
    @State private var exercises: [DailyRecordExerciseInput] = []
    @State private var durationMinutes = ""
    @State private var distanceKm = ""
    @State private var selectedCardioActivity: CardioActivityType = .running
    @State private var path: [Route] = []
    @State private var isSaving = false
    @State private var saveError: String?

    let onSave: (DailyRecordDraft) async throws -> Void

    private var formSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.85)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 14) {
                    modePicker

                    if mode == .cardio {
                        cardioCard
                    } else {
                        strengthContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .dismissKeyboardOnTap()
            .navigationTitle("daily_record.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("daily_record.save", action: save)
                        .fontWeight(.semibold)
                        .foregroundColor(recordDraft == nil ? .textMuted : .accentPrimary)
                        .disabled(recordDraft == nil || isSaving)
                }
            }
            .overlay(alignment: .bottom) {
                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .picker:
                    ExercisePickerScreen(
                        alreadyAddedIds: Set(exercises.compactMap(\.sourceExerciseId)),
                        onConfirm: appendPicked
                    )
                }
            }
        }
    }

    private func appendPicked(_ picked: [ExerciseDefinition]) {
        let language = localizationManager.appLanguage
        withAnimation(formSpring) {
            exercises.append(contentsOf: picked.map { DailyRecordExerciseInput(definition: $0, language: language) })
        }
        path.removeLast(path.count)
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(DailyRecordMode.allCases) { candidate in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        mode = candidate
                    }
                } label: {
                    Text(candidate.title)
                        .appFont(size: 14, weight: .semibold)
                        .foregroundColor(mode == candidate ? .white : .textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if mode == candidate {
                                Capsule().fill(LinearGradient.accentGradient)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.workoutPanel))
        .accessibilityIdentifier("dailyRecord.modePicker")
    }

    // MARK: - Strength

    private var strengthContent: some View {
        VStack(spacing: 14) {
            TextField(String(localized: "daily_record.session_title"), text: $title)
                .appFont(.chatBodyMedium)
                .foregroundColor(.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .fill(Color.workoutPanel)
                )

            ForEach($exercises) { $exercise in
                ExerciseFormCard(
                    exercise: $exercise,
                    canDelete: true,
                    onDelete: {
                        withAnimation(formSpring) {
                            exercises.removeAll { $0.id == exercise.id }
                        }
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            AddExerciseDashedButton {
                path.append(.picker)
            }
        }
    }

    // MARK: - Cardio

    private var cardioCard: some View {
        VStack(spacing: 10) {
            Picker("cardio.metric.activity", selection: $selectedCardioActivity) {
                ForEach(CardioActivityType.allCases, id: \.self) { activity in
                    Label(activity.title, systemImage: activity.iconName).tag(activity)
                }
            }
            .pickerStyle(.menu)
            cardioField(
                labelKey: "daily_record.duration",
                placeholder: "45",
                keyboardType: .numberPad,
                text: $durationMinutes
            )
            if selectedCardioActivity.supportsDistance {
                cardioField(
                    labelKey: "daily_record.distance",
                    placeholder: String(localized: "cardio.metric.optional"),
                    keyboardType: .decimalPad,
                    text: $distanceKm
                )
            }
        }
        .padding(12)
        .glassPanel(cornerRadius: AppRadius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.accentPrimary.opacity(0.14), lineWidth: 1)
        )
    }

    private func cardioField(
        labelKey: String.LocalizationValue,
        placeholder: String,
        keyboardType: UIKeyboardType,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 12) {
            Text(String(localized: labelKey))
                .appFont(.chatBodyMedium)
                .foregroundColor(.textSecondary)

            Spacer()

            TextField(placeholder, text: text)
                .keyboardType(keyboardType)
                .appFont(.exerciseValue)
                .foregroundColor(.accentValue)
                .multilineTextAlignment(.center)
                .frame(width: 120, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .fill(Color.workoutPanel)
                )
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Draft

    private var recordDraft: DailyRecordDraft? {
        switch mode {
        case .strength:
            return DailyRecordDraftBuilder.strengthDraft(
                title: title,
                workoutDate: Date(),
                exercises: exercises
            ).map(DailyRecordDraft.strength)
        case .cardio:
            guard let duration = Int(durationMinutes) else { return nil }
            guard distanceKm.isEmpty || Double(distanceKm) != nil else { return nil }
            let distance = selectedCardioActivity.supportsDistance && !distanceKm.isEmpty
                ? Double(distanceKm) : nil
            guard let metrics = try? CardioMetrics(
                activityType: selectedCardioActivity,
                durationMinutes: duration,
                distanceKm: distance
            ) else { return nil }
            return .cardio(metrics)
        }
    }

    private func save() {
        guard let recordDraft else { return }
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                try await onSave(recordDraft)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}

#Preview {
    DailyRecordSheet { _ in }
        .environmentObject(LocalizationManager())
}
