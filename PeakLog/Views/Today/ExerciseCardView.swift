import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Set Row (editable weight × reps)

private struct SetRowView: View {
    let setIndex: Int
    let exerciseId: String?
    let exerciseName: String
    let exerciseLoadType: ExerciseLoadType?
    let precedingSet: ExerciseSet?
    @Binding var set: ExerciseSet

    @State private var editingWeight: Bool = false
    @State private var editingReps: Bool = false
    @State private var weightSuggestion: SetDefaultsSuggestion?
    @State private var repsSuggestion: SetDefaultsSuggestion?

    var onCommit: (Double?, WeightUnit, Int) -> Void

    private var allowsBodyweightToggle: Bool {
        exerciseLoadType == .bodyweight || (exerciseLoadType == nil && set.weight == nil)
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("\(setIndex)")
                .font(.setIndex)
                .foregroundColor(.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.workoutIndexFill))

            valueChip(action: { presentWeightEditor() }) {
                LoadValueLabel(weight: set.weight, weightUnit: set.weightUnit, isBodyweight: allowsBodyweightToggle && set.weight == nil)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.xl)
                            .fill(Color.workoutPanel)
                    )
            }

            Text("×")
                .font(.setIndex)
                .foregroundColor(Color.accentBorder.opacity(0.55))

            valueChip(action: { presentRepsEditor() }) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(set.reps)")
                        .font(.exerciseValue)
                        .foregroundColor(.accentValue)
                    Text("chat.exercise.reps")
                        .font(.exerciseUnit)
                        .foregroundColor(.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .fill(Color.workoutPanel)
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xxl)
                .fill(Color.workoutShell)
        )
        .sheet(isPresented: $editingWeight) {
            WeightWheelEditSheet(
                allowsBodyweightToggle: allowsBodyweightToggle,
                weightUnit: set.weightUnit,
                initialWeight: set.weight,
                lastTime: weightSuggestion
            ) { weight in
                set.weight = weight
                onCommit(weight, set.weightUnit, set.reps)
                editingWeight = false
            } onCancel: {
                editingWeight = false
            }
            .presentationDetents([.height(allowsBodyweightToggle ? 420 : 380)])
        }
        .sheet(isPresented: $editingReps) {
            RepsWheelEditSheet(initialReps: set.reps, lastTime: repsSuggestion) { reps in
                set.reps = reps
                onCommit(set.weight, set.weightUnit, reps)
                editingReps = false
            } onCancel: {
                editingReps = false
            }
            .presentationDetents([.height(360)])
        }
    }

    private func presentWeightEditor() {
        Task {
            weightSuggestion = await AppServices.setDefaultsProvider.suggestDefaults(for: SetDefaultsContext(
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                setIndex: setIndex,
                precedingSetInSameExercise: precedingSet.map {
                    SetDefaultsSuggestion(weight: $0.weight, weightUnit: $0.weightUnit, reps: $0.reps)
                }
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
                precedingSetInSameExercise: precedingSet.map {
                    SetDefaultsSuggestion(weight: $0.weight, weightUnit: $0.weightUnit, reps: $0.reps)
                }
            ))
            editingReps = true
        }
    }
}

func formatWeightValue(_ weight: Double) -> String {
    weight.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(weight)) : String(format: "%.1f", weight)
}

// MARK: - Exercise Card (swipeable)

struct ExerciseCardView: View {
    @Binding var exercise: Exercise
    var isEditable: Bool = true
    var onSetChanged: (ExerciseSet) -> Void
    var onAddSet: (() -> Void)? = nil
    var onDeleteLastSet: (() -> Void)? = nil

    var body: some View {
        cardContent
    }

    @ViewBuilder
    private var cardContent: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: AppRadius.full)
                        .fill(Color.accentPrimary)
                        .frame(width: 5, height: 22)

                    Text(exercise.name)
                        .font(.exerciseName)
                        .foregroundColor(.textPrimary)

                    Spacer()

                    if isEditable, let onDeleteLastSet, exercise.sets.count > 1 {
                        Button(action: onDeleteLastSet) {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.textMuted)
                        }
                    }

                    if isEditable, let onAddSet {
                        Button(action: onAddSet) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.accentPrimary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xxl)
                        .fill(Color.workoutPanel.opacity(0.5))
                )

                VStack(spacing: 6) {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, _ in
                        SetRowView(
                            setIndex: index + 1,
                            exerciseId: exercise.exerciseId,
                            exerciseName: exercise.name,
                            exerciseLoadType: exercise.exerciseLoadType,
                            precedingSet: index > 0 ? exercise.sets[index - 1] : nil,
                            set: $exercise.sets[index]
                        ) { weight, unit, reps in
                            guard isEditable else { return }
                            var updated = exercise.sets[index]
                            updated.weight = weight
                            updated.weightUnit = unit
                            updated.reps = reps
                            onSetChanged(updated)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xxl)
                .fill(Color.appSurface)
        )
        .cornerRadius(AppRadius.xxl)
        .contentShape(Rectangle())
        .allowsHitTesting(isEditable)

        content
    }
}

private extension SetRowView {
    func valueChip<Content: View>(
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var exercise = MockData.benchPress
    ExerciseCardView(
        exercise: $exercise,
        isEditable: true,
        onSetChanged: { _ in }
    )
    .padding()
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
