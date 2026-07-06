import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Set Row (editable weight × reps)

private struct SetRowView: View {
    let setIndex: Int
    @Binding var set: ExerciseSet

    @State private var editingWeight: Bool = false
    @State private var editingReps: Bool = false
    @State private var weightText: String = ""
    @State private var repsText: String = ""

    var onCommit: (Double?, WeightUnit, Int) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text("\(setIndex)")
                .font(.setIndex)
                .foregroundColor(.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.workoutIndexFill))

            valueChip(action: {
                weightText = set.weight.map(formatWeightValue) ?? ""
                editingWeight = true
            }) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let weight = set.weight {
                        Text(formatWeightValue(weight))
                            .font(.exerciseValue)
                            .foregroundColor(.accentValue)
                        Text(set.weightUnit.display)
                            .font(.exerciseUnit)
                            .foregroundColor(.textSecondary)
                    } else {
                        Text("chat.exercise.bodyweight")
                            .font(.exerciseValue)
                            .foregroundColor(.accentValue)
                    }
                }
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

            valueChip(action: {
                repsText = "\(set.reps)"
                editingReps = true
            }) {
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
        // Edit weight sheet
        .sheet(isPresented: $editingWeight) {
            ValueEditSheet(
                title: String(localized: "chat.exercise.weight"),
                titleKey: "chat.exercise.edit_weight",
                unit: set.weight == nil ? nil : set.weightUnit.display,
                placeholder: String(localized: "chat.exercise.bodyweight"),
                keyboardType: .decimalPad,
                value: $weightText
            ) {
                let trimmed = weightText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    set.weight = nil
                    onCommit(nil, set.weightUnit, set.reps)
                } else if let w = Double(trimmed) {
                    set.weight = w
                    onCommit(w, set.weightUnit, set.reps)
                }
                editingWeight = false
            } onCancel: {
                editingWeight = false
            }
            .presentationDetents([.height(220)])
        }
        // Edit reps sheet
        .sheet(isPresented: $editingReps) {
            ValueEditSheet(
                title: String(localized: "chat.exercise.reps"),
                titleKey: "chat.exercise.edit_reps",
                unit: String(localized: "chat.exercise.reps"),
                placeholder: "0",
                keyboardType: .numberPad,
                value: $repsText
            ) {
                if let r = Int(repsText) {
                    set.reps = r
                    onCommit(set.weight, set.weightUnit, r)
                }
                editingReps = false
            } onCancel: {
                editingReps = false
            }
            .presentationDetents([.height(220)])
        }
    }
}

func formatWeightValue(_ weight: Double) -> String {
    weight.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(weight)) : String(format: "%.1f", weight)
}

// MARK: - Inline Edit Sheet

struct ValueEditSheet: View {
    let title: String
    let titleKey: String?
    let unit: String?
    let placeholder: String
    let keyboardType: UIKeyboardType
    @Binding var value: String
    var onDone: () -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text(titleKey.map { String(localized: String.LocalizationValue($0)) } ?? title)
                .font(.headerTitle)
                .foregroundColor(.textPrimary)
                .padding(.top, 24)

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                TextField(placeholder, text: $value)
                    .keyboardType(keyboardType)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.accentValue)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .frame(width: 120)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button(String(localized: "common.done")) {
                                focused = false
                                onDone()
                            }
                        }
                    }

                if let unit {
                    Text(unit)
                        .font(.settingTitle)
                        .foregroundColor(.textMuted)
                }
            }

            HStack(spacing: 16) {
                Button(String(localized: "common.cancel")) { onCancel() }
                    .foregroundColor(.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.appSurface)
                    .cornerRadius(AppRadius.lg)

                Button(String(localized: "common.done")) { onDone() }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(LinearGradient.accentGradient)
                    .cornerRadius(AppRadius.lg)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color.appCard)
        .dismissKeyboardOnTap()
        .onAppear { focused = true }
    }
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
