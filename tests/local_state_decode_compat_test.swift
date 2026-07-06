import Foundation

@main
struct LocalStateDecodeCompatTestRunner {
    static func main() async {
        await legacyStateFileWithoutCustomExercisesLoads()
        await customExercisesPersistAcrossReopen()
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
