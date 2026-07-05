import SwiftUI

struct AddPlanExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var exercises: [DailyRecordExerciseInput] = [DailyRecordExerciseInput()]

    let onSave: ([PlanExerciseDraft]) async -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
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
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .dismissKeyboardOnTap()
            .navigationTitle("add_plan_exercise.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("daily_record.save", action: save)
                        .fontWeight(.semibold)
                        .foregroundColor(drafts == nil ? .textMuted : .accentPrimary)
                        .disabled(drafts == nil)
                }
            }
        }
    }

    private var drafts: [PlanExerciseDraft]? {
        PlanExerciseDraftBuilder.drafts(exercises: exercises)
    }

    private func save() {
        guard let drafts else { return }
        Task {
            await onSave(drafts)
            dismiss()
        }
    }
}

#Preview {
    AddPlanExerciseSheet { _ in }
}
