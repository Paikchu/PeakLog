import SwiftUI

enum DailyRecordDraft: Equatable {
    case strength(StrengthSessionDraft)
    case cardio(durationMinutes: Int, distanceKm: Double)
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

    @State private var mode: DailyRecordMode = .strength
    @State private var title = ""
    @State private var exercises: [DailyRecordExerciseInput] = [DailyRecordExerciseInput()]
    @State private var durationMinutes = ""
    @State private var distanceKm = ""

    let onSave: (DailyRecordDraft) async -> Void

    var body: some View {
        NavigationStack {
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
                        .disabled(recordDraft == nil)
                }
            }
        }
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
                        .font(.system(size: 14, weight: .semibold))
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
                .font(.chatBodyMedium)
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
                    canDelete: exercises.count > 1,
                    onDelete: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            exercises.removeAll { $0.id == exercise.id }
                        }
                    }
                )
            }

            AddExerciseDashedButton {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    exercises.append(DailyRecordExerciseInput())
                }
            }
        }
    }

    // MARK: - Cardio

    private var cardioCard: some View {
        VStack(spacing: 10) {
            cardioField(
                labelKey: "daily_record.duration",
                placeholder: "45",
                keyboardType: .numberPad,
                text: $durationMinutes
            )
            cardioField(
                labelKey: "daily_record.distance",
                placeholder: "5.0",
                keyboardType: .decimalPad,
                text: $distanceKm
            )
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
                .font(.chatBodyMedium)
                .foregroundColor(.textSecondary)

            Spacer()

            TextField(placeholder, text: text)
                .keyboardType(keyboardType)
                .font(.exerciseValue)
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
            guard let duration = Int(durationMinutes), duration > 0,
                  let distance = Double(distanceKm), distance > 0 else { return nil }
            return .cardio(durationMinutes: duration, distanceKm: distance)
        }
    }

    private func save() {
        guard let recordDraft else { return }
        Task {
            await onSave(recordDraft)
            dismiss()
        }
    }
}

#Preview {
    DailyRecordSheet { _ in }
}
