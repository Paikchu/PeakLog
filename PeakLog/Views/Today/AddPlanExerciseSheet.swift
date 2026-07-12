import SwiftUI

// MARK: - Add Plan Exercise Sheet
// Picker-first flow: the sheet opens on the exercise library picker; a
// multi-select confirm pushes the set/weight form with cards prebuilt from
// the picked definitions. The form's dashed add button pops back to the
// picker with prior picks marked as already added.

struct AddPlanExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localizationManager: LocalizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Route: Hashable {
        case form
    }

    @State private var exercises: [DailyRecordExerciseInput] = []
    @State private var path: [Route] = []
    @State private var appearedCardIds: Set<UUID> = []
    @State private var isSaving = false
    @State private var saveError: String?

    let onSave: ([PlanExerciseDraft]) async throws -> Void

    private var formSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.85)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ExercisePickerScreen(
                alreadyAddedIds: Set(exercises.compactMap(\.sourceExerciseId)),
                onConfirm: appendPicked
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .form:
                    formPage
                }
            }
        }
    }

    // MARK: - Form Page

    private var formPage: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach($exercises) { $exercise in
                    ExerciseFormCard(
                        exercise: $exercise,
                        canDelete: exercises.count > 1,
                        onDelete: {
                            withAnimation(formSpring) {
                                exercises.removeAll { $0.id == exercise.id }
                            }
                        }
                    )
                    .opacity(appearedCardIds.contains(exercise.id) ? 1 : 0)
                    .offset(y: appearedCardIds.contains(exercise.id) || reduceMotion ? 0 : 12)
                    .onAppear { revealCard(exercise.id) }
                }

                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                AddExerciseDashedButton {
                    path.removeLast(path.count)
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
            ToolbarItem(placement: .confirmationAction) {
                Button("daily_record.save", action: save)
                    .fontWeight(.semibold)
                    .foregroundColor(drafts == nil ? .textMuted : .accentPrimary)
                    .disabled(drafts == nil || isSaving)
            }
        }
        .onChange(of: exercises.isEmpty) { _, isEmpty in
            if isEmpty {
                path.removeLast(path.count)
            }
        }
    }

    // MARK: - Actions

    private func appendPicked(_ picked: [ExerciseDefinition]) {
        let language = localizationManager.appLanguage
        exercises.append(contentsOf: picked.map { DailyRecordExerciseInput(definition: $0, language: language) })
        path.append(.form)
    }

    /// Staggers newly pushed cards in — 50ms steps, matching the form spring.
    private func revealCard(_ id: UUID) {
        guard !appearedCardIds.contains(id) else { return }
        let pending = exercises.filter { !appearedCardIds.contains($0.id) }
        let step = pending.firstIndex { $0.id == id } ?? 0
        withAnimation(formSpring.delay(reduceMotion ? 0 : Double(step) * 0.05)) {
            _ = appearedCardIds.insert(id)
        }
    }

    private var drafts: [PlanExerciseDraft]? {
        PlanExerciseDraftBuilder.drafts(exercises: exercises)
    }

    private func save() {
        guard let drafts else { return }
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                try await onSave(drafts)
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
    AddPlanExerciseSheet { _ in }
        .environmentObject(LocalizationManager())
}
