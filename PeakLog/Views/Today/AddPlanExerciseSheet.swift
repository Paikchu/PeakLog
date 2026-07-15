import SwiftUI

// MARK: - Add Plan Exercise Sheet

struct AddPlanExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localizationManager: LocalizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Route: Hashable {
        case form
    }

    @State private var formItems: [PlanExerciseFormItem] = []
    @State private var path: [Route] = []
    @State private var appearedCardIDs: Set<UUID> = []
    @State private var isSaving = false
    @State private var saveError: String?

    let onSave: ([PlanExerciseDraft]) async throws -> Void

    private var formSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.85)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ExercisePickerScreen(
                alreadyAddedItemIDs: Set(formItems.map(\.pickerItemID)),
                onConfirm: appendPicked,
                supportsCardio: true
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

    private var formPage: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(formItems) { item in
                    formCard(for: item)
                        .opacity(appearedCardIDs.contains(item.id) ? 1 : 0)
                        .offset(y: appearedCardIDs.contains(item.id) || reduceMotion ? 0 : 12)
                        .onAppear { revealCard(item.id) }
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
        .onChange(of: formItems.isEmpty) { _, isEmpty in
            if isEmpty {
                path = []
            }
        }
    }

    @ViewBuilder
    private func formCard(for item: PlanExerciseFormItem) -> some View {
        if let index = formItems.firstIndex(where: { $0.id == item.id }) {
            switch item {
            case .strength(let input):
                ExerciseFormCard(
                    exercise: strengthBinding(at: index, fallback: input),
                    canDelete: true,
                    onDelete: { removeFormItem(id: item.id) }
                )
            case .cardio(let input):
                CardioPlanFormCard(
                    input: cardioBinding(at: index, fallback: input),
                    onDelete: { removeFormItem(id: item.id) }
                )
            }
        }
    }

    private func strengthBinding(
        at index: Int,
        fallback: DailyRecordExerciseInput
    ) -> Binding<DailyRecordExerciseInput> {
        Binding(
            get: {
                guard formItems.indices.contains(index), case .strength(let input) = formItems[index] else {
                    return fallback
                }
                return input
            },
            set: { input in
                guard formItems.indices.contains(index) else { return }
                formItems[index] = .strength(input)
            }
        )
    }

    private func cardioBinding(
        at index: Int,
        fallback: CardioPlanExerciseInput
    ) -> Binding<CardioPlanExerciseInput> {
        Binding(
            get: {
                guard formItems.indices.contains(index), case .cardio(let input) = formItems[index] else {
                    return fallback
                }
                return input
            },
            set: { input in
                guard formItems.indices.contains(index) else { return }
                formItems[index] = .cardio(input)
            }
        )
    }

    private func appendPicked(_ picked: [ExercisePickerItem]) {
        let language = localizationManager.appLanguage
        formItems.append(contentsOf: picked.map { item in
            switch item {
            case .strength(let definition):
                .strength(DailyRecordExerciseInput(definition: definition, language: language))
            case .cardio(let activity):
                .cardio(CardioPlanExerciseInput(activityType: activity))
            }
        })
        path.append(.form)
    }

    private func removeFormItem(id: UUID) {
        withAnimation(formSpring) {
            formItems.removeAll { $0.id == id }
        }
    }

    private func revealCard(_ id: UUID) {
        guard !appearedCardIDs.contains(id) else { return }
        let pending = formItems.filter { !appearedCardIDs.contains($0.id) }
        let step = pending.firstIndex { $0.id == id } ?? 0
        withAnimation(formSpring.delay(reduceMotion ? 0 : Double(step) * 0.05)) {
            _ = appearedCardIDs.insert(id)
        }
    }

    private var drafts: [PlanExerciseDraft]? {
        PlanExerciseDraftBuilder.drafts(items: formItems)
    }

    private func save() {
        guard let drafts, !isSaving else { return }
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

private struct CardioPlanFormCard: View {
    @Binding var input: CardioPlanExerciseInput
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(spacing: 6) {
                metricField("cardio.metric.duration", text: $input.durationText, suffix: "min")
                if input.activityType.supportsDistance {
                    metricField("cardio.metric.distance", text: $input.distanceText, suffix: "km", decimal: true)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .padding(8)
        .glassPanel(cornerRadius: AppRadius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .strokeBorder(Color.accentPrimary.opacity(0.14), lineWidth: 1)
        )
        .accessibilityIdentifier("addPlan.cardioForm")
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: AppRadius.full)
                .fill(Color.accentPrimary)
                .frame(width: 5, height: 22)

            Text(input.activityType.localizedTitle)
                .appFont(.exerciseName)
                .foregroundColor(.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text("daily_record.type.cardio")
                .appFont(size: 12, weight: .medium)
                .foregroundColor(.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.workoutPanel))

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundColor(.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "daily_record.delete_exercise"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xxl)
                .fill(Color.workoutPanel.opacity(0.5))
        )
    }

    private func metricField(
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
        .background(Color.workoutPanel.opacity(0.5))
        .cornerRadius(AppRadius.xl)
    }
}

#Preview {
    AddPlanExerciseSheet { _ in }
        .environmentObject(LocalizationManager())
}
