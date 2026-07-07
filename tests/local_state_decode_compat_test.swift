import Foundation

@main
struct LocalStateDecodeCompatTestRunner {
    static func main() async {
        await legacyStateFileWithoutCustomExercisesLoads()
        await customExercisesPersistAcrossReopen()
        await legacyStateFileWithoutPhase1FieldsLoads()
        print("local_state_decode_compat_test passed")
    }

    private static func tempFileURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-decode-compat-\(UUID().uuidString)")
            .appendingPathComponent(name)
    }

    /// Simulates a state file written before the exercise library existed by
    /// stripping the customExercises key from a freshly seeded file.
    private static func legacyStateFileWithoutCustomExercisesLoads() async {
        let seededURL = tempFileURL("seeded.json")
        let seededDatabase = LocalAppDatabase(fileURL: seededURL)
        let originalProfile = await seededDatabase.fetchProfile()
        let originalPlan = await seededDatabase.activePlan()
        let originalSessions = await seededDatabase.allStrengthSessions()

        guard let data = try? Data(contentsOf: seededURL),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            preconditionFailure("Expected seeded state file to be readable JSON")
        }
        precondition(json["customExercises"] != nil, "Seeded file should contain the new key")
        json.removeValue(forKey: "customExercises")

        let legacyURL = tempFileURL("legacy.json")
        try? FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let legacyData = try? JSONSerialization.data(withJSONObject: json) else {
            preconditionFailure("Expected legacy JSON to serialize")
        }
        try? legacyData.write(to: legacyURL)

        let legacyDatabase = LocalAppDatabase(fileURL: legacyURL)
        let profile = await legacyDatabase.fetchProfile()
        let plan = await legacyDatabase.activePlan()
        let sessions = await legacyDatabase.allStrengthSessions()
        let custom = await legacyDatabase.customExercises()

        precondition(profile.id == originalProfile.id, "Legacy file must load, not be replaced by a fresh seed")
        precondition(plan?.id == originalPlan?.id, "Active plan must survive the legacy decode")
        precondition(sessions.count == originalSessions.count, "Sessions must survive the legacy decode")
        precondition(custom.isEmpty, "Missing key decodes as an empty custom library")
    }

    /// Simulates a state file written before Phase 1 (goalSpec /
    /// pendingEditEvents / editEventSeq) existed. SY4: a file missing these
    /// keys must load with safe defaults, not fail or reseed.
    private static func legacyStateFileWithoutPhase1FieldsLoads() async {
        let seededURL = tempFileURL("phase1-seeded.json")
        let seededDatabase = LocalAppDatabase(fileURL: seededURL)
        let originalProfile = await seededDatabase.fetchProfile()

        guard let data = try? Data(contentsOf: seededURL),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            preconditionFailure("Expected seeded state file to be readable JSON")
        }
        // goalSpec is Optional and nil by default, so the synthesized encoder
        // already omits it — nothing to strip there. pendingEditEvents/
        // editEventSeq are non-optional (default `[]`/`0`), so they ARE
        // written; strip them to simulate a file from before Phase 1 existed.
        precondition(json["goalSpec"] == nil, "nil optional should already be omitted by the encoder")
        for key in ["pendingEditEvents", "editEventSeq"] {
            precondition(json[key] != nil, "Seeded file should contain the new key \(key)")
        }
        json.removeValue(forKey: "pendingEditEvents")
        json.removeValue(forKey: "editEventSeq")

        let legacyURL = tempFileURL("phase1-legacy.json")
        try? FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let legacyData = try? JSONSerialization.data(withJSONObject: json) else {
            preconditionFailure("Expected legacy JSON to serialize")
        }
        try? legacyData.write(to: legacyURL)

        let legacyDatabase = LocalAppDatabase(fileURL: legacyURL)
        let profile = await legacyDatabase.fetchProfile()
        precondition(profile.id == originalProfile.id, "Legacy file must load, not be replaced by a fresh seed")

        let snapshot = await legacyDatabase.snapshot()
        precondition(snapshot.goalSpec == nil, "Missing goalSpec key decodes as nil")
        precondition(snapshot.pendingEditEvents.isEmpty, "Missing pendingEditEvents key decodes as empty")

        // The database must still be fully usable after loading a legacy
        // file — arming and recording a new event must work normally, with
        // the sequence counter starting fresh from 0.
        await legacyDatabase.armCloudSync(userId: "user-a") {}
        _ = try! await legacyDatabase.addPlannedExercises([
            PlanExerciseDraft(exerciseName: "Lat Pulldown", exerciseId: nil, isBodyweight: false,
                sets: [.init(targetWeight: 45, targetWeightUnit: .kg, targetReps: 10)])
        ])
        let events = await legacyDatabase.snapshot().pendingEditEvents
        precondition(events.count == 1 && events[0].clientSeq == 1, "editEventSeq must start from 0 when missing, not crash or skip")
    }

    private static func customExercisesPersistAcrossReopen() async {
        let fileURL = tempFileURL("custom.json")
        let database = LocalAppDatabase(fileURL: fileURL)

        guard let created = try? await database.addCustomExercise(
            name: " 地雷管推举 ",
            muscleGroup: .shoulders,
            loadType: .weighted
        ) else {
            preconditionFailure("Expected custom exercise creation to succeed")
        }
        precondition(created.nameZH == "地雷管推举", "Name should be trimmed")
        precondition(created.isCustom)
        precondition(created.id.hasPrefix("custom-"))

        if let duplicate = try? await database.addCustomExercise(
            name: "地雷管推举",
            muscleGroup: .arms,
            loadType: .weighted
        ) {
            precondition(duplicate.id == created.id, "Same normalized name must return the existing definition")
        } else {
            preconditionFailure("Duplicate-name creation should return the existing definition")
        }

        let emptyName = try? await database.addCustomExercise(name: "  ", muscleGroup: .core, loadType: .bodyweight)
        precondition(emptyName == nil, "Blank names must be rejected")

        let reopened = LocalAppDatabase(fileURL: fileURL)
        let custom = await reopened.customExercises()
        precondition(custom.count == 1, "Custom exercise must persist across reopen")
        precondition(custom.first?.id == created.id)
    }
}
