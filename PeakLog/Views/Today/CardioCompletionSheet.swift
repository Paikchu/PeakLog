import SwiftUI

struct CardioCompletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: TrainingPlanExercise
    let onSave: (CardioMetrics) async throws -> Void

    @State private var durationText: String
    @State private var distanceText: String
    @State private var rpeText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(exercise: TrainingPlanExercise, onSave: @escaping (CardioMetrics) async throws -> Void) {
        self.exercise = exercise
        self.onSave = onSave
        _durationText = State(initialValue: exercise.targetDurationMinutes.map(String.init) ?? "")
        _distanceText = State(initialValue: exercise.targetDistanceKm.map { $0.cleanDistance } ?? "")
        _rpeText = State(initialValue: exercise.targetRPE.map { $0.cleanRPE } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("cardio.metric.activity", value: activityType.title)
                    numericField("cardio.metric.duration", text: $durationText, suffix: "min")
                    if activityType.supportsDistance {
                        numericField("cardio.metric.distance", text: $distanceText, suffix: "km", decimal: true)
                    }
                    numericField("cardio.metric.rpe", text: $rpeText, suffix: "1–10", decimal: true)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundColor(.red) }
                }
            }
            .navigationTitle("cardio.plan.complete_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done", action: save)
                        .disabled(metrics == nil || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var activityType: CardioActivityType {
        exercise.cardioActivityType ?? .running
    }

    private var metrics: CardioMetrics? {
        guard let duration = Int(durationText) else { return nil }
        guard distanceText.isEmpty || Double(distanceText) != nil,
              rpeText.isEmpty || Double(rpeText) != nil else { return nil }
        let distance = distanceText.isEmpty ? nil : Double(distanceText)
        let rpe = rpeText.isEmpty ? nil : Double(rpeText)
        return try? CardioMetrics(
            activityType: activityType,
            durationMinutes: duration,
            distanceKm: distance,
            rpe: rpe
        )
    }

    private func numericField(
        _ key: LocalizedStringKey,
        text: Binding<String>,
        suffix: String,
        decimal: Bool = false
    ) -> some View {
        HStack {
            Text(key)
            Spacer()
            TextField("", text: text)
                .keyboardType(decimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Text(suffix).foregroundColor(.textMuted)
        }
    }

    private func save() {
        guard let metrics, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(metrics)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private extension Double {
    var cleanDistance: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(format: "%.1f", self)
    }

    var cleanRPE: String { cleanDistance }
}
