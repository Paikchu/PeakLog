import Foundation

@main
struct ExercisePickerRecentTestRunner {
    static func main() {
        derivesRecentsFromHistoryWithOrdering()
        resolvesLegacyFreeTextNames()
        excludesUnknownExercisesAndHonorsLimit()
        print("exercise_picker_recent_test passed")
    }

    private static let bench = ExerciseDefinition(
        id: "barbell-bench-press",
        nameEN: "Bench Press",
        nameZH: "杠铃卧推",
        aliases: ["卧推"],
        muscleGroup: .chest,
        equipment: .barbell,
        loadType: .weighted,
        popularity: 98
    )

    private static let squat = ExerciseDefinition(
        id: "barbell-squat",
        nameEN: "Squat",
        nameZH: "杠铃深蹲",
        aliases: ["深蹲"],
        muscleGroup: .legs,
        equipment: .barbell,
        loadType: .weighted,
        popularity: 97
    )

    private static let pullUp = ExerciseDefinition(
        id: "pull-up",
        nameEN: "Pull-Up",
        nameZH: "引体向上",
        aliases: ["引体"],
        muscleGroup: .back,
        equipment: .bodyweight,
        loadType: .bodyweight,
        popularity: 95
    )

    private static var library: [ExerciseDefinition] { [bench, squat, pullUp] }

    private static func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_750_000_000 + TimeInterval(offset * 86_400))
    }

    private static func session(id: String, date: Date, exercises: [Exercise]) -> WorkoutSession {
        WorkoutSession(
            id: id,
            userId: "test-user",
            date: date,
            durationMinutes: nil,
            label: nil,
            exercises: exercises,
            createdAt: date,
            updatedAt: date
        )
    }

    private static func set(_ index: Int, weight: Double?, reps: Int) -> ExerciseSet {
        ExerciseSet(id: UUID().uuidString, setIndex: index, weight: weight, weightUnit: .kg, reps: reps, rpe: nil)
    }

    private static func derivesRecentsFromHistoryWithOrdering() {
        let sessions = [
            session(id: "s1", date: day(0), exercises: [
                Exercise(id: "e1", name: "Bench Press", exerciseId: "barbell-bench-press", sets: [
                    set(1, weight: 60, reps: 8),
                    set(2, weight: 62.5, reps: 6),
                ]),
                Exercise(id: "e2", name: "Squat", exerciseId: "barbell-squat", sets: [set(1, weight: 100, reps: 5)]),
            ]),
            session(id: "s2", date: day(2), exercises: [
                Exercise(id: "e3", name: "Squat", exerciseId: "barbell-squat", sets: [set(1, weight: 105, reps: 5)]),
            ]),
        ]

        let recents = ExerciseLibraryEngine.recentEntries(sessions: sessions, library: library, limit: 10)
        precondition(recents.map(\.definition.id) == ["barbell-squat", "barbell-bench-press"], "Most recently performed first")
        precondition(recents[0].timesPerformed == 2)
        precondition(recents[0].lastWeight == 105, "Summary must come from the most recent session")
        precondition(recents[1].lastWeight == 62.5, "Top set by weight is the summary set")
        precondition(recents[1].lastReps == 6)
    }

    private static func resolvesLegacyFreeTextNames() {
        let sessions = [
            session(id: "s1", date: day(0), exercises: [
                Exercise(id: "e1", name: "卧推", sets: [set(1, weight: 50, reps: 10)]),
                Exercise(id: "e2", name: " PULL up ", sets: [set(1, weight: nil, reps: 12)]),
            ]),
        ]

        let recents = ExerciseLibraryEngine.recentEntries(sessions: sessions, library: library, limit: 10)
        precondition(recents.count == 2, "Legacy names should resolve via alias/name normalization")
        precondition(recents.contains { $0.definition.id == "barbell-bench-press" })
        let pullUpEntry = recents.first { $0.definition.id == "pull-up" }
        precondition(pullUpEntry != nil, "Whitespace/case differences should still resolve")
        precondition(pullUpEntry?.lastWeight == nil)
        precondition(pullUpEntry?.lastReps == 12)
    }

    private static func excludesUnknownExercisesAndHonorsLimit() {
        var sessions = [
            session(id: "s0", date: day(9), exercises: [
                Exercise(id: "e0", name: "自创神秘动作", sets: [set(1, weight: 10, reps: 10)]),
            ]),
        ]
        for (offset, definition) in [bench, squat, pullUp].enumerated() {
            sessions.append(
                session(id: "s\(offset + 1)", date: day(offset), exercises: [
                    Exercise(id: "e\(offset + 1)", name: definition.nameEN, exerciseId: definition.id, sets: [set(1, weight: 20, reps: 5)]),
                ])
            )
        }

        let all = ExerciseLibraryEngine.recentEntries(sessions: sessions, library: library, limit: 10)
        precondition(all.count == 3, "Names with no library match are excluded")

        let limited = ExerciseLibraryEngine.recentEntries(sessions: sessions, library: library, limit: 2)
        precondition(limited.count == 2, "Limit caps the recent list")
        precondition(limited.map(\.definition.id) == ["pull-up", "barbell-squat"], "Limit keeps the most recent entries")
    }
}
