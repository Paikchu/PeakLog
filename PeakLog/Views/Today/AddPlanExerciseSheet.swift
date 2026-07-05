import SwiftUI

struct AddPlanExerciseDraft: Equatable {
    let exerciseName: String
    let loadType: ExerciseLoadType
    let targetWeight: Double?
    let targetWeightUnit: WeightUnit
    let targetReps: Int
    let setsCount: Int
}

struct AddPlanExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var exerciseName = ""
    @State private var loadType: ExerciseLoadType = .weighted
    @State private var weight = ""
    @State private var reps = "8"
    @State private var setsCount = "3"

    let onSave: (AddPlanExerciseDraft) async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("add_plan_exercise.exercise") {
                    TextField(String(localized: "add_plan_exercise.name"), text: $exerciseName)

                    Picker(String(localized: "add_plan_exercise.load_type"), selection: $loadType) {
                        Text("daily_record.type.strength").tag(ExerciseLoadType.weighted)
                        Text("daily_record.type.bodyweight").tag(ExerciseLoadType.bodyweight)
                    }
                    .pickerStyle(.segmented)
                }

                Section("add_plan_exercise.targets") {
                    if loadType == .weighted {
                        TextField(String(localized: "daily_record.weight"), text: $weight)
                            .keyboardType(.decimalPad)
                    }
                    TextField(String(localized: "add_plan_exercise.reps_per_set"), text: $reps)
                        .keyboardType(.numberPad)
                    TextField(String(localized: "add_plan_exercise.sets_count"), text: $setsCount)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("add_plan_exercise.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("daily_record.save", action: save)
                        .disabled(draft == nil)
                }
            }
        }
    }

    private var draft: AddPlanExerciseDraft? {
        let name = exerciseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard let repCount = Int(reps), repCount > 0 else { return nil }
        guard let sets = Int(setsCount), sets > 0 else { return nil }

        let parsedWeight = Double(weight.trimmingCharacters(in: .whitespacesAndNewlines))
        guard loadType == .bodyweight || parsedWeight != nil else { return nil }

        return AddPlanExerciseDraft(
            exerciseName: name,
            loadType: loadType,
            targetWeight: loadType == .bodyweight ? nil : parsedWeight,
            targetWeightUnit: .kg,
            targetReps: repCount,
            setsCount: sets
        )
    }

    private func save() {
        guard let draft else { return }
        Task {
            await onSave(draft)
            dismiss()
        }
    }
}

#Preview {
    AddPlanExerciseSheet { _ in }
}
