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
                        isBodyweight: exercise.isBodyweight,
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
                .font(.exerciseName)
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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.textMuted)
                }
                .buttonStyle(.plain)
            }

            if canDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
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
                .font(.system(size: 12, weight: .medium))
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
                .font(.system(size: 13, weight: .semibold))
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
    let isBodyweight: Bool
    @Binding var set: DailyRecordSetInput

    @State private var editingWeight = false
    @State private var editingReps = false
    @State private var weightText = ""
    @State private var repsText = ""

    var body: some View {
        HStack(spacing: 14) {
            Text("\(setIndex)")
                .font(.setIndex)
                .foregroundColor(.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.workoutIndexFill))

            weightChip

            Text("×")
                .font(.setIndex)
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
            ValueEditSheet(
                title: String(localized: "chat.exercise.weight"),
                titleKey: "chat.exercise.edit_weight",
                unit: WeightUnit.kg.display,
                placeholder: "0",
                keyboardType: .decimalPad,
                value: $weightText
            ) {
                let trimmed = weightText.trimmingCharacters(in: .whitespacesAndNewlines)
                set.weight = trimmed.isEmpty ? nil : Double(trimmed)
                editingWeight = false
            } onCancel: {
                editingWeight = false
            }
            .presentationDetents([.height(280)])
        }
        .sheet(isPresented: $editingReps) {
            ValueEditSheet(
                title: String(localized: "chat.exercise.reps"),
                titleKey: "chat.exercise.edit_reps",
                unit: String(localized: "chat.exercise.reps"),
                placeholder: "0",
                keyboardType: .numberPad,
                value: $repsText
            ) {
                if let reps = Int(repsText) {
                    set.reps = reps
                }
                editingReps = false
            } onCancel: {
                editingReps = false
            }
            .presentationDetents([.height(280)])
        }
    }

    @ViewBuilder
    private var weightChip: some View {
        if isBodyweight {
            Text("daily_record.load.bodyweight")
                .font(.exerciseValue)
                .foregroundColor(.accentValue)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.xl)
                        .fill(Color.workoutPanel)
                )
        } else {
            Button {
                weightText = set.weight.map(formatWeightValue) ?? ""
                editingWeight = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let weight = set.weight {
                        Text(formatWeightValue(weight))
                            .font(.exerciseValue)
                            .foregroundColor(.accentValue)
                        Text(WeightUnit.kg.display)
                            .font(.exerciseUnit)
                            .foregroundColor(.textSecondary)
                    } else {
                        Text("daily_record.weight")
                            .font(.exerciseValue)
                            .foregroundColor(.textMuted)
                    }
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
    }

    private var repsChip: some View {
        Button {
            repsText = "\(set.reps)"
            editingReps = true
        } label: {
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
        .buttonStyle(.plain)
    }
}

// MARK: - Add Exercise Button

struct AddExerciseDashedButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(String(localized: "daily_record.add_exercise"), systemImage: "plus")
                .font(.system(size: 14, weight: .semibold))
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
