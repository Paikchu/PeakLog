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
    var messageId: String
    var isEditable: Bool = true
    var onDeleteExercise: () -> Void
    var onSetChanged: (ExerciseSet) -> Void
    var onAddSet: (() -> Void)? = nil
    var onDeleteLastSet: (() -> Void)? = nil

    @State private var offset: CGFloat = 0
    private let deleteWidth: CGFloat = 72
    private let swipeCoordinator = ExerciseCardSwipeGestureCoordinator()

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                guard isEditable else { return }
                withAnimation(.spring()) { offset = 0 }
                onDeleteExercise()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                    Text("common.delete")
                        .font(.deleteLabel)
                        .foregroundColor(.white)
                }
                .frame(width: deleteWidth)
                .frame(maxHeight: .infinity)
                .background(Color.accentRed)
                .cornerRadius(AppRadius.xxl, corners: [.topRight, .bottomRight])
            }

            cardContent
        }
        .clipped()
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
        .offset(x: offset)
        .contentShape(Rectangle())
        .allowsHitTesting(isEditable)
        #if canImport(UIKit)
        .background {
            if isEditable {
                ExerciseCardPanGesture(
                    swipeCoordinator: swipeCoordinator,
                    onChanged: { translation in
                        let decision = swipeCoordinator.decision(
                            translation: translation,
                            currentOffset: offset,
                            deleteWidth: deleteWidth
                        )
                        offset = decision.nextOffset
                    },
                    onEnded: { translation in
                        withAnimation(.spring(response: 0.3)) {
                            offset = swipeCoordinator.finalOffset(
                                translation: translation,
                                currentOffset: offset,
                                deleteWidth: deleteWidth,
                                lockedAxis: .horizontal
                            )
                        }
                    }
                )
                .allowsHitTesting(false)
            }
        }
        #endif

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

// MARK: - Corner Radius Helper

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

private struct RoundedCorner: Shape {
    var radius: CGFloat = 0
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var exercise = MockData.benchPress
    ExerciseCardView(
        exercise: $exercise,
        messageId: "m-1",
        isEditable: true,
        onDeleteExercise: {},
        onSetChanged: { _ in }
    )
    .padding()
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
