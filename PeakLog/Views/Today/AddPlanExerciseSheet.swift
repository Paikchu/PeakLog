import SwiftUI

// MARK: - Add Plan Exercise Sheet
// Strength and cardio begin in one picker, then route to their own target forms.

struct AddPlanExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localizationManager: LocalizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Route: Hashable {
        case strengthForm
        case cardioForm
    }

    @State private var exercises: [DailyRecordExerciseInput] = []
    @State private var path: [Route] = []
    @State private var appearedCardIds: Set<UUID> = []
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var selectedCardioActivity: CardioActivityType = .running
    @State private var cardioDuration = "30"
    @State private var cardioDistance = ""

    let onSave: ([PlanExerciseDraft]) async throws -> Void

    private var formSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.85)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ExercisePickerScreen(
                alreadyAddedIds: Set(exercises.compactMap(\.sourceExerciseId)),
                onConfirm: appendPicked,
                onSelectCardio: selectCardio
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .strengthForm:
                    formPage
                case .cardioForm:
                    cardioFormPage
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
                    path = []
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
                path = []
            }
        }
    }

    // MARK: - Actions

    private func appendPicked(_ picked: [ExerciseDefinition]) {
        let language = localizationManager.appLanguage
        exercises.append(contentsOf: picked.map { DailyRecordExerciseInput(definition: $0, language: language) })
        path.append(.strengthForm)
    }

    private func selectCardio(_ activity: CardioActivityType) {
        selectedCardioActivity = activity
        if !activity.supportsDistance {
            cardioDistance = ""
        }
        path.append(.cardioForm)
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

    private var cardioFormPage: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: selectedCardioActivity.iconName)
                        .foregroundColor(.teal)
                    Text(selectedCardioActivity.localizedTitle)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(14)
                .background(Color.appSurface)
                .cornerRadius(AppRadius.xl)

                cardioField("cardio.metric.duration", text: $cardioDuration, suffix: "min")
                if selectedCardioActivity.supportsDistance {
                    cardioField("cardio.metric.distance", text: $cardioDistance, suffix: "km", decimal: true)
                }
                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .dismissKeyboardOnTap()
        .navigationTitle("add_plan_exercise.cardio_title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("daily_record.save") {
                    guard let cardioDraft else { return }
                    save([cardioDraft])
                }
                .fontWeight(.semibold)
                .disabled(cardioDraft == nil || isSaving)
            }
        }
        .accessibilityIdentifier("addPlan.cardioForm")
    }

    private var cardioDraft: PlanExerciseDraft? {
        guard let duration = Int(cardioDuration),
              cardioDistance.isEmpty || Double(cardioDistance) != nil else { return nil }
        let distance = selectedCardioActivity.supportsDistance && !cardioDistance.isEmpty
            ? Double(cardioDistance) : nil
        return try? PlanExerciseDraft.cardio(
            activityType: selectedCardioActivity,
            targetDurationMinutes: duration,
            targetDistanceKm: distance
        )
    }

    private func cardioField(
        _ key: LocalizedStringKey,
        text: Binding<String>,
        suffix: String,
        decimal: Bool = false
    ) -> some View {
        HStack {
            Text(key)
                .foregroundColor(.textSecondary)
            Spacer()
            TextField("", text: text)
                .keyboardType(decimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Text(suffix)
                .foregroundColor(.textMuted)
        }
        .padding(14)
        .background(Color.appSurface)
        .cornerRadius(AppRadius.xl)
    }

    private func save() {
        guard let drafts else { return }
        save(drafts)
    }

    private func save(_ drafts: [PlanExerciseDraft]) {
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
