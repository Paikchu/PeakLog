import SwiftUI

// MARK: - Shared Exercise Form Components
// Themed building blocks used by DailyRecordSheet (manual record) and
// AddPlanExerciseSheet (add to plan). Both edit [DailyRecordExerciseInput].

struct ExerciseFormCard: View {
    @Binding var exercise: DailyRecordExerciseInput
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(spacing: 6) {
                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, _ in
                    ExerciseFormSetRow(
                        setIndex: index + 1,
                        exerciseId: exercise.sourceExerciseId,
                        exerciseName: exercise.name,
                        isBodyweight: exercise.isBodyweight,
                        precedingSet: index > 0 ? exercise.sets[index - 1] : nil,
                        set: $exercise.sets[index]
                    )
                }
            }
            .padding(.horizontal, 6)

            addSetButton
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .padding(8)
        .glassPanel(cornerRadius: AppRadius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.accentPrimary.opacity(0.14), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: AppRadius.full)
                .fill(Color.accentPrimary)
                .frame(width: 5, height: 22)

            // Names come from the exercise library picker, so the header is read-only.
            Text(exercise.name)
                .appFont(.exerciseName)
                .foregroundColor(.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            loadTypeToggle

            if exercise.sets.count > 1 {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        exercise.removeLastSet()
                    }
                } label: {
                    Image(systemName: "minus.circle")
                        .appFont(size: 16, weight: .semibold)
                        .foregroundColor(.textMuted)
                }
                .buttonStyle(.plain)
            }

            if canDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .appFont(size: 14, weight: .semibold)
                        .foregroundColor(.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "daily_record.delete_exercise"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xxl)
                .fill(Color.workoutPanel.opacity(0.5))
        )
    }

    private var loadTypeToggle: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                exercise.isBodyweight.toggle()
            }
        } label: {
            Text(exercise.isBodyweight ? "daily_record.load.bodyweight" : "daily_record.load.weighted")
                .appFont(size: 12, weight: .medium)
                .foregroundColor(exercise.isBodyweight ? .accentValue : .textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.workoutPanel))
        }
        .buttonStyle(.plain)
    }

    private var addSetButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                exercise.appendSetCopyingLast()
            }
        } label: {
            Label(String(localized: "daily_record.add_set"), systemImage: "plus.circle.fill")
                .appFont(size: 13, weight: .semibold)
                .foregroundColor(.accentPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .fill(Color.workoutPanel.opacity(0.5))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Set Row

struct ExerciseFormSetRow: View {
    let setIndex: Int
    let exerciseId: String?
    let exerciseName: String
    let isBodyweight: Bool
    let precedingSet: DailyRecordSetInput?
    @Binding var set: DailyRecordSetInput

    @State private var editingWeight = false
    @State private var editingReps = false
    @State private var weightSuggestion: SetDefaultsSuggestion?
    @State private var repsSuggestion: SetDefaultsSuggestion?

    var body: some View {
        HStack(spacing: 14) {
            Text("\(setIndex)")
                .appFont(.setIndex)
                .foregroundColor(.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.workoutIndexFill))

            weightChip

            Text("×")
                .appFont(.setIndex)
                .foregroundColor(Color.accentBorder.opacity(0.55))

            repsChip
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xxl)
                .fill(Color.workoutShell)
        )
        .sheet(isPresented: $editingWeight) {
            WeightWheelEditSheet(
                allowsBodyweightToggle: isBodyweight,
                weightUnit: .kg,
                initialWeight: set.weight,
                lastTime: weightSuggestion
            ) { weight in
                set.weight = weight
                editingWeight = false
            } onCancel: {
                editingWeight = false
            }
            .presentationDetents([.height(isBodyweight ? 420 : 380)])
        }
        .sheet(isPresented: $editingReps) {
            RepsWheelEditSheet(initialReps: set.reps, lastTime: repsSuggestion) { reps in
                set.reps = reps
                editingReps = false
            } onCancel: {
                editingReps = false
            }
            .presentationDetents([.height(360)])
        }
    }

    private var weightChip: some View {
        Button {
            presentWeightEditor()
        } label: {
            LoadValueLabel(
                weight: set.weight,
                weightUnit: .kg,
                isBodyweight: isBodyweight && set.weight == nil,
                unsetPlaceholder: isBodyweight ? nil : String(localized: "daily_record.weight")
            )
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .fill(Color.workoutPanel)
                )
        }
        .buttonStyle(.plain)
    }

    private var repsChip: some View {
        Button {
            presentRepsEditor()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(set.reps)")
                    .appFont(.exerciseValue)
                    .foregroundColor(.accentValue)
                Text("chat.exercise.reps")
                    .appFont(.exerciseUnit)
                    .foregroundColor(.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xl)
                    .fill(Color.workoutPanel)
            )
        }
        .buttonStyle(.plain)
    }

    private func precedingSuggestion() -> SetDefaultsSuggestion? {
        precedingSet.map { SetDefaultsSuggestion(weight: $0.weight, weightUnit: .kg, reps: $0.reps) }
    }

    private func presentWeightEditor() {
        Task {
            weightSuggestion = await AppServices.setDefaultsProvider.suggestDefaults(for: SetDefaultsContext(
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                setIndex: setIndex,
                precedingSetInSameExercise: precedingSuggestion()
            ))
            editingWeight = true
        }
    }

    private func presentRepsEditor() {
        Task {
            repsSuggestion = await AppServices.setDefaultsProvider.suggestDefaults(for: SetDefaultsContext(
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                setIndex: setIndex,
                precedingSetInSameExercise: precedingSuggestion()
            ))
            editingReps = true
        }
    }
}

// MARK: - Add Exercise Button

struct AddExerciseDashedButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(String(localized: "daily_record.add_exercise"), systemImage: "plus")
                .appFont(size: 14, weight: .semibold)
                .foregroundColor(.accentPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .strokeBorder(
                            Color.accentPrimary.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("exerciseForm.addExercise")
    }
}
