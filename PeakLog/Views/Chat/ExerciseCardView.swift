import SwiftUI

// MARK: - Set Row (editable weight × reps)

private struct SetRowView: View {
    let setIndex: Int
    @Binding var set: ExerciseSet

    @State private var editingWeight: Bool = false
    @State private var editingReps: Bool = false
    @State private var weightText: String = ""
    @State private var repsText: String = ""

    var onCommit: (Double, WeightUnit, Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Set index
            Text("#\(setIndex)")
                .font(.setIndex)
                .foregroundColor(.textDarkMuted)
                .frame(width: 24, alignment: .leading)

            // Weight button
            Button {
                weightText = set.weight.formatted()
                editingWeight = true
            } label: {
                HStack(spacing: 4) {
                    Text(set.weight.formatted())
                        .font(.exerciseValue)
                        .foregroundColor(.accentValue)
                    Text(set.weightUnit.display)
                        .font(.exerciseUnit)
                        .foregroundColor(.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.04))
                .cornerRadius(AppRadius.sm)
            }
            .buttonStyle(.plain)

            // Multiplier
            Text("×")
                .font(.setIndex)
                .foregroundColor(.textDarkMuted)
                .padding(.horizontal, 8)

            // Reps button
            Button {
                repsText = "\(set.reps)"
                editingReps = true
            } label: {
                HStack(spacing: 4) {
                    Text("\(set.reps)")
                        .font(.exerciseValue)
                        .foregroundColor(.accentValue)
                    Text("chat.exercise.reps")
                        .font(.exerciseUnit)
                        .foregroundColor(.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.04))
                .cornerRadius(AppRadius.sm)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        // Edit weight sheet
        .sheet(isPresented: $editingWeight) {
            ValueEditSheet(
                title: String(localized: "chat.exercise.weight"),
                unit: set.weightUnit.display,
                value: $weightText
            ) {
                if let w = Double(weightText) {
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
                unit: String(localized: "chat.exercise.reps"),
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

// MARK: - Inline Edit Sheet

private struct ValueEditSheet: View {
    let title: String
    let unit: String
    @Binding var value: String
    var onDone: () -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit \(title)")
                .font(.headerTitle)
                .foregroundColor(.textPrimary)
                .padding(.top, 24)

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                TextField("0", text: $value)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.accentValue)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .frame(width: 120)

                Text(unit)
                    .font(.settingTitle)
                    .foregroundColor(.textMuted)
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
    var onDeleteExercise: () -> Void
    var onSetChanged: (ExerciseSet) -> Void

    @State private var offset: CGFloat = 0
    private let deleteWidth: CGFloat = 72

    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete panel (revealed on swipe)
            Button {
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
                .cornerRadius(AppRadius.lg, corners: [.topRight, .bottomRight])
            }

            // Card content
            VStack(alignment: .leading, spacing: 6) {
                Text(exercise.name)
                    .font(.exerciseName)
                    .foregroundColor(.textPrimary)

                VStack(spacing: 0) {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, _ in
                        SetRowView(
                            setIndex: index + 1,
                            set: $exercise.sets[index]
                        ) { weight, unit, reps in
                            var updated = exercise.sets[index]
                            updated.weight = weight
                            updated.weightUnit = unit
                            updated.reps = reps
                            onSetChanged(updated)
                        }
                        if index < exercise.sets.count - 1 {
                            Divider().background(Color.appSeparator.opacity(0.6))
                        }
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appCard)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.accentBorder, lineWidth: 2.5)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle().frame(width: 2.5)
                            Spacer()
                        }
                    )
            )
            .cornerRadius(AppRadius.lg)
            .offset(x: offset)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        let delta = value.translation.width
                        if delta < 0 {
                            offset = max(-deleteWidth, delta)
                        } else {
                            offset = min(0, (offset < 0 ? -deleteWidth : 0) + delta)
                        }
                    }
                    .onEnded { value in
                        withAnimation(.spring(response: 0.3)) {
                            if value.translation.width < -deleteWidth / 2 {
                                offset = -deleteWidth
                            } else {
                                offset = 0
                            }
                        }
                    }
            )
        }
        .clipped()
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
        onDeleteExercise: {},
        onSetChanged: { _ in }
    )
    .padding()
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
