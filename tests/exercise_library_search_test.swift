import Foundation

@main
struct ExerciseLibrarySearchTestRunner {
    static func main() {
        matchesBilingualNamesAndAliases()
        filtersByMuscleGroupAndEquipment()
        groupsByMuscleWithPopularityOrder()
        mergesSeedAndCustomWithoutDuplicates()
        resolvesExactNameMatches()
        print("exercise_library_search_test passed")
    }

    private static let bench = ExerciseDefinition(
        id: "barbell-bench-press",
        nameEN: "Bench Press",
        nameZH: "杠铃卧推",
        aliases: ["卧推", "bp"],
        muscleGroup: .chest,
        equipment: .barbell,
        loadType: .weighted,
        popularity: 98
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

    private static let fly = ExerciseDefinition(
        id: "dumbbell-fly",
        nameEN: "Dumbbell Fly",
        nameZH: "哑铃飞鸟",
        aliases: ["飞鸟"],
        muscleGroup: .chest,
        equipment: .dumbbell,
        loadType: .weighted,
        popularity: 75
    )

    private static var library: [ExerciseDefinition] { [bench, pullUp, fly] }

    private static func matchesBilingualNamesAndAliases() {
        precondition(bench.matches(query: "卧推"), "Chinese name substring should match")
        precondition(bench.matches(query: "bench"), "English name should match case-insensitively")
        precondition(bench.matches(query: "BP"), "Alias should match case-insensitively")
        precondition(bench.matches(query: " bench  press "), "Whitespace should be ignored")
        precondition(bench.matches(query: ""), "Empty query matches everything")
        precondition(!bench.matches(query: "深蹲"), "Unrelated query must not match")
        precondition(pullUp.matches(query: "引体"), "Alias 引体 should match")
    }

    private static func filtersByMuscleGroupAndEquipment() {
        let chest = ExerciseLibraryEngine.filter(library, muscleGroup: .chest)
        precondition(chest.map(\.id).sorted() == ["barbell-bench-press", "dumbbell-fly"])

        let chestDumbbell = ExerciseLibraryEngine.filter(library, muscleGroup: .chest, equipment: .dumbbell)
        precondition(chestDumbbell.map(\.id) == ["dumbbell-fly"])

        let searchWithinGroup = ExerciseLibraryEngine.filter(library, query: "卧推", muscleGroup: .chest)
        precondition(searchWithinGroup.map(\.id) == ["barbell-bench-press"])

        let noMatch = ExerciseLibraryEngine.filter(library, query: "地雷管推举")
        precondition(noMatch.isEmpty, "Unknown query should return empty results")
    }

    private static func groupsByMuscleWithPopularityOrder() {
        let groups = ExerciseLibraryEngine.groupedByMuscle(library)
        precondition(groups.count == 2, "Only groups with content should appear")
        precondition(groups[0].group == .chest, "Groups follow MuscleGroup.allCases order")
        precondition(groups[0].exercises.map(\.id) == ["barbell-bench-press", "dumbbell-fly"], "Higher popularity first within a group")
        precondition(groups[1].group == .back)
    }

    private static func mergesSeedAndCustomWithoutDuplicates() {
        let custom = ExerciseDefinition(
            id: "custom-abc",
            nameEN: "地雷管推举",
            nameZH: "地雷管推举",
            muscleGroup: .shoulders,
            equipment: .other,
            loadType: .weighted,
            popularity: 0,
            isCustom: true
        )
        let merged = ExerciseLibraryEngine.merged(seed: library, custom: [custom, bench])
        precondition(merged.count == 4, "Custom entry sharing a seed id must be dropped")
        precondition(merged.contains(where: { $0.id == "custom-abc" }))
    }

    private static func resolvesExactNameMatches() {
        precondition(ExerciseLibraryEngine.exactNameMatch("卧推", in: library)?.id == "barbell-bench-press", "Alias exact match should resolve")
        precondition(ExerciseLibraryEngine.exactNameMatch("Bench Press", in: library)?.id == "barbell-bench-press")
        precondition(ExerciseLibraryEngine.exactNameMatch("卧", in: library) == nil, "Partial name is not an exact match")
        precondition(ExerciseLibraryEngine.exactNameMatch("  ", in: library) == nil, "Blank query resolves to nothing")
    }
}
