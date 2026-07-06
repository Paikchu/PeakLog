import Foundation

@main
struct ExerciseRecommendationTestRunner {
    static func main() {
        excludesGroupsTrainedYesterdayButNotThreeDaysAgo()
        coreRecoversAfterOneDay()
        selectionDrivesCoOccurrenceAndAffinity()
        saturatedGroupYieldsToSynergists()
        todaysTrainingIsNotExcluded()
        coldStartFallsBackToPopularityAndHonorsLimit()
        print("exercise_recommendation_test passed")
    }

    // MARK: - Fixtures

    private static let bench = definition("barbell-bench-press", "Bench Press", "杠铃卧推", .chest, .barbell, popularity: 98)
    private static let fly = definition("dumbbell-fly", "Dumbbell Fly", "哑铃飞鸟", .chest, .dumbbell, popularity: 75)
    private static let inclinePress = definition("incline-dumbbell-press", "Incline Dumbbell Press", "上斜哑铃卧推", .chest, .dumbbell, popularity: 88)
    private static let squat = definition("barbell-squat", "Squat", "杠铃深蹲", .legs, .barbell, popularity: 97)
    private static let legPress = definition("leg-press", "Leg Press", "腿举", .legs, .machine, popularity: 92)
    private static let row = definition("barbell-row", "Barbell Row", "杠铃划船", .back, .barbell, popularity: 90)
    private static let lateralRaise = definition("dumbbell-lateral-raise", "Lateral Raise", "哑铃侧平举", .shoulders, .dumbbell, popularity: 92)
    private static let pushdown = definition("triceps-pushdown", "Triceps Pushdown", "绳索下压", .arms, .cable, popularity: 90)
    private static let plank = definition("plank", "Plank", "平板支撑", .core, .bodyweight, popularity: 90)

    private static var library: [ExerciseDefinition] {
        [bench, fly, inclinePress, squat, legPress, row, lateralRaise, pushdown, plank]
    }

    private static func definition(
        _ id: String,
        _ nameEN: String,
        _ nameZH: String,
        _ group: MuscleGroup,
        _ equipment: Equipment,
        popularity: Int
    ) -> ExerciseDefinition {
        ExerciseDefinition(
            id: id,
            nameEN: nameEN,
            nameZH: nameZH,
            muscleGroup: group,
            equipment: equipment,
            loadType: equipment == .bodyweight ? .bodyweight : .weighted,
            popularity: popularity
        )
    }

    private static let baseDate = Date(timeIntervalSince1970: 1_760_000_000)

    private static func daysAgo(_ days: Int) -> Date {
        baseDate.addingTimeInterval(TimeInterval(-days * 86_400))
    }

    private static func session(_ id: String, date: Date, _ definitions: [ExerciseDefinition]) -> WorkoutSession {
        WorkoutSession(
            id: id,
            userId: "test-user",
            date: date,
            durationMinutes: nil,
            label: nil,
            exercises: definitions.map { definition in
                Exercise(
                    id: UUID().uuidString,
                    name: definition.nameEN,
                    exerciseId: definition.id,
                    sets: [ExerciseSet(id: UUID().uuidString, setIndex: 1, weight: 50, weightUnit: .kg, reps: 8, rpe: nil)]
                )
            },
            createdAt: date,
            updatedAt: date
        )
    }

    private static func recommend(
        sessions: [WorkoutSession],
        selections: [ExerciseDefinition] = [],
        limit: Int = 8
    ) -> [ExerciseDefinition] {
        ExerciseRecommendationEngine.recommend(
            RecommendationContext(
                library: library,
                sessions: sessions,
                todaysSelections: selections,
                today: baseDate,
                limit: limit
            )
        )
    }

    // MARK: - Scenarios

    private static func excludesGroupsTrainedYesterdayButNotThreeDaysAgo() {
        let legDayYesterday = [session("s1", date: daysAgo(1), [squat, legPress])]
        let result = recommend(sessions: legDayYesterday)
        precondition(!result.isEmpty)
        precondition(result.allSatisfy { $0.muscleGroup != .legs }, "Legs trained yesterday must be excluded")

        let legDayThreeDaysAgo = [session("s1", date: daysAgo(3), [squat, legPress])]
        let recovered = recommend(sessions: legDayThreeDaysAgo)
        precondition(recovered.contains { $0.muscleGroup == .legs }, "Legs trained 3 days ago should reappear")
    }

    private static func coreRecoversAfterOneDay() {
        let coreYesterday = [session("s1", date: daysAgo(1), [plank])]
        let excluded = recommend(sessions: coreYesterday)
        precondition(excluded.allSatisfy { $0.id != plank.id }, "Core trained yesterday is excluded")

        let coreTwoDaysAgo = [session("s1", date: daysAgo(2), [plank])]
        let recovered = recommend(sessions: coreTwoDaysAgo)
        precondition(recovered.contains { $0.id == plank.id }, "Core recovers after one rest day")
    }

    private static func selectionDrivesCoOccurrenceAndAffinity() {
        // History: bench is always trained together with fly, never with row.
        let sessions = [
            session("s1", date: daysAgo(7), [bench, fly]),
            session("s2", date: daysAgo(5), [bench, fly]),
            session("s3", date: daysAgo(9), [row]),
        ]
        let result = recommend(sessions: sessions, selections: [bench])

        precondition(!result.contains { $0.id == bench.id }, "Selected exercise must not be recommended")
        precondition(result.first?.id == fly.id, "Frequent co-occurrence should rank first, got \(result.map(\.id))")

        let flyIndex = result.firstIndex { $0.id == fly.id } ?? .max
        let rowIndex = result.firstIndex { $0.id == row.id } ?? .max
        precondition(flyIndex < rowIndex, "Co-trained exercise outranks unrelated group")

        let chestIndex = result.firstIndex { $0.id == inclinePress.id } ?? .max
        precondition(chestIndex < rowIndex, "Same muscle group outranks unrelated group")
    }

    private static func saturatedGroupYieldsToSynergists() {
        let result = recommend(sessions: [], selections: [bench, fly, inclinePress])
        let chestIndex = result.firstIndex { $0.muscleGroup == .chest }
        let shoulderIndex = result.firstIndex { $0.id == lateralRaise.id } ?? .max
        let armsIndex = result.firstIndex { $0.id == pushdown.id } ?? .max

        precondition(shoulderIndex != .max && armsIndex != .max, "Synergists must be present")
        if let chestIndex {
            precondition(shoulderIndex < chestIndex && armsIndex < chestIndex, "After 3 chest picks synergists outrank more chest, got \(result.map(\.id))")
        }
    }

    private static func todaysTrainingIsNotExcluded() {
        // Chest was logged today; picking more chest is today's direction,
        // not a recovery violation.
        let sessions = [session("s1", date: baseDate, [bench])]
        let result = recommend(sessions: sessions, selections: [bench])
        precondition(result.contains { $0.muscleGroup == .chest }, "Today's own group must stay eligible, got \(result.map(\.id))")
    }

    private static func coldStartFallsBackToPopularityAndHonorsLimit() {
        let result = recommend(sessions: [])
        let popularities = result.map(\.popularity)
        precondition(popularities == popularities.sorted(by: >), "Cold start ranks by popularity, got \(popularities)")

        let limited = recommend(sessions: [], limit: 3)
        precondition(limited.count == 3, "Limit caps the suggestion list")

        let zero = recommend(sessions: [], limit: 0)
        precondition(zero.isEmpty)
    }
}
