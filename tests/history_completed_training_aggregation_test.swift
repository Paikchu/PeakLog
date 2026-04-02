import Foundation

@main
struct HistoryCompletedTrainingAggregationTestRunner {
    static func main() async {
        await buildsCompletedTrainingSummaryForStrengthAndCardio()
        validatesStrengthLoadDisplayModes()
        print("history_completed_training_aggregation_test passed")
    }

    @MainActor
    private static func buildsCompletedTrainingSummaryForStrengthAndCardio() async {
        let formatter = WorkoutDateFormatter()
        let targetDate = formatter.date(from: "2026-04-02") ?? Date()

        let sessions = [
            WorkoutSession(
                id: "session-1",
                userId: "user-1",
                date: targetDate,
                durationMinutes: 42,
                label: "Push Day",
                exercises: [
                    Exercise(
                        id: "exercise-1",
                        name: "杠铃卧推",
                        sets: [
                            ExerciseSet(id: "set-1", setIndex: 1, weight: 40, weightUnit: .kg, reps: 5, rpe: 8),
                            ExerciseSet(id: "set-2", setIndex: 2, weight: 42.5, weightUnit: .kg, reps: 5, rpe: 8.5),
                        ]
                    ),
                    Exercise(
                        id: "exercise-2",
                        name: "双杠臂屈伸",
                        sets: [
                            ExerciseSet(id: "set-3", setIndex: 1, weight: nil, weightUnit: .kg, reps: 12, rpe: 7)
                        ]
                    ),
                ],
                createdAt: targetDate,
                updatedAt: targetDate
            )
        ]

        let records = [
            RunningWorkoutRecord(
                id: "run-1",
                userId: "user-1",
                workoutDate: targetDate,
                durationMinutes: 26,
                distanceKm: 4.2,
                source: .manual,
                createdAt: targetDate.addingTimeInterval(3600),
                updatedAt: targetDate.addingTimeInterval(3600)
            )
        ]

        let summary = HistoryCompletedAggregator.daySummary(
            selectedDate: targetDate,
            sessions: sessions,
            runningRecords: records
        )
        let strengthExercises = HistoryCompletedAggregator.strengthExercises(from: sessions)
        let cardioRecords = HistoryCompletedAggregator.cardioRecords(from: records)

        precondition(summary.strengthExerciseCount == 2, "Expected two completed strength exercises")
        precondition(summary.strengthSetCount == 3, "Expected three completed strength sets")
        precondition(summary.cardioRecordCount == 1, "Expected one cardio record")
        precondition(summary.totalDurationMinutes == 68, "Expected merged duration to include strength and cardio")
        precondition(summary.totalDistanceKm == 4.2, "Expected cardio distance to be included in summary")
        precondition(strengthExercises.count == 2, "Expected two strength cards")
        precondition(cardioRecords.count == 1, "Expected one cardio card")
        precondition(cardioRecords[0].paceText == "6:11 /km", "Expected pace to be derived from duration and distance")
    }

    private static func validatesStrengthLoadDisplayModes() {
        let mixedExercise = Exercise(
            id: "exercise-mixed",
            name: "哑铃卧推",
            sets: [
                ExerciseSet(id: "mixed-1", setIndex: 1, weight: 22.5, weightUnit: .kg, reps: 10),
                ExerciseSet(id: "mixed-2", setIndex: 2, weight: nil, weightUnit: .kg, reps: 10),
            ]
        )

        let bodyweightExercise = Exercise(
            id: "exercise-bodyweight",
            name: "俯卧撑",
            sets: [
                ExerciseSet(id: "bw-1", setIndex: 1, weight: nil, weightUnit: .kg, reps: 20),
            ]
        )

        let sessions = [
            WorkoutSession(
                id: "session-load-display",
                userId: "user-1",
                date: Date(),
                durationMinutes: nil,
                label: nil,
                exercises: [mixedExercise, bodyweightExercise],
                createdAt: Date(),
                updatedAt: Date()
            )
        ]

        let cards = HistoryCompletedAggregator.strengthExercises(from: sessions)
        guard cards.count == 2 else {
            preconditionFailure("Expected two strength cards for load display validation")
        }

        precondition(cards[0].sets[0].loadDisplay == .weighted(22.5, .kg), "Expected explicit weight to stay weighted")
        precondition(cards[0].sets[1].loadDisplay == .unrecordedWeight, "Expected nil weight inside a weighted exercise to render as unrecorded")
        precondition(cards[1].sets[0].loadDisplay == .bodyweight, "Expected all-nil exercise to render as bodyweight")
    }
}
