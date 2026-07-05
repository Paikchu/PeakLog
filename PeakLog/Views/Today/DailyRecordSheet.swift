import SwiftUI

enum DailyRecordDraft: Equatable {
    case strength(StrengthSessionDraft)
    case cardio(durationMinutes: Int, distanceKm: Double)
}

private enum DailyRecordMode: String, CaseIterable, Identifiable {
    case strength
    case bodyweight
    case cardio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strength:
            return String(localized: "daily_record.type.strength")
        case .bodyweight:
            return String(localized: "daily_record.type.bodyweight")
        case .cardio:
            return String(localized: "daily_record.type.cardio")
        }
    }
}

struct DailyRecordSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var mode: DailyRecordMode = .strength
    @State private var title = ""
    @State private var exerciseName = ""
    @State private var weight = ""
    @State private var reps = ""
    @State private var sets = "3"
    @State private var durationMinutes = ""
    @State private var distanceKm = ""

    let onSave: (DailyRecordDraft) async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "daily_record.type"), selection: $mode) {
                        ForEach(DailyRecordMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .cardio {
                    cardioFields
                } else {
                    strengthFields
                }
            }
            .navigationTitle("daily_record.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("daily_record.save", action: save)
                        .disabled(recordDraft == nil)
                }
            }
        }
    }

    private var strengthFields: some View {
        Group {
            Section("daily_record.session") {
                TextField(String(localized: "daily_record.session_title"), text: $title)
            }

            Section("daily_record.exercise") {
                TextField(String(localized: "daily_record.exercise_name"), text: $exerciseName)
                if mode == .strength {
                    TextField(String(localized: "daily_record.weight"), text: $weight)
                        .keyboardType(.decimalPad)
                }
                TextField(String(localized: "daily_record.reps"), text: $reps)
                    .keyboardType(.numberPad)
                TextField(String(localized: "daily_record.sets"), text: $sets)
                    .keyboardType(.numberPad)
            }
        }
    }

    private var cardioFields: some View {
        Section("daily_record.type.cardio") {
            TextField(String(localized: "daily_record.duration"), text: $durationMinutes)
                .keyboardType(.numberPad)
            TextField(String(localized: "daily_record.distance"), text: $distanceKm)
                .keyboardType(.decimalPad)
        }
    }

    private var recordDraft: DailyRecordDraft? {
        switch mode {
        case .strength, .bodyweight:
            let name = exerciseName.trimmingCharacters(in: .whitespacesAndNewlines)
            let setCount = Int(sets) ?? 0
            let repCount = Int(reps) ?? 0
            guard !name.isEmpty, setCount > 0, repCount > 0 else { return nil }

            let parsedWeight = Double(weight.trimmingCharacters(in: .whitespacesAndNewlines))
            guard mode == .bodyweight || parsedWeight != nil else { return nil }

            let setDrafts = (0..<setCount).map { _ in
                StrengthSessionDraft.ExerciseDraft.SetDraft(
                    weight: mode == .bodyweight ? nil : parsedWeight,
                    weightUnit: .kg,
                    reps: repCount,
                    rpe: nil
                )
            }
            return .strength(StrengthSessionDraft(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                workoutDate: Date(),
                exercises: [StrengthSessionDraft.ExerciseDraft(name: name, sets: setDrafts)]
            ))
        case .cardio:
            guard let duration = Int(durationMinutes), duration > 0,
                  let distance = Double(distanceKm), distance > 0 else { return nil }
            return .cardio(durationMinutes: duration, distanceKm: distance)
        }
    }

    private func save() {
        guard let recordDraft else { return }
        Task {
            await onSave(recordDraft)
            dismiss()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#Preview {
    DailyRecordSheet { _ in }
}
