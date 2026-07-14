import XCTest
@testable import PeakLog

/// Issue #3: PR comparison used to compare raw numeric weight without
/// normalizing units, so e.g. a 150lbs set (~68kg) could wrongly be judged a
/// PR over a 90kg set just because 150 > 90. These tests pin the fix:
/// `ExercisePR` comparisons must always happen on the kg-normalized value.
///
/// Issue #4: `ProfileViewModel.volumeDisplay` used to hardcode "kg"/"t"
/// regardless of the user's preferred unit, and truncated tonnes with
/// `%.0f` (1500kg displayed as "2t" instead of "1.5t"). These tests pin the
/// fix: the display respects `preferences.weightUnit` and rounds to one
/// decimal place.
@MainActor
final class ExercisePRUnitAndVolumeDisplayTests: XCTestCase {
    private var databaseFileURL: URL!
    private var database: LocalAppDatabase!

    override func setUp() {
        super.setUp()
        databaseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("exercise-pr-unit-tests-\(UUID().uuidString).json")
        database = LocalAppDatabase(fileURL: databaseFileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: databaseFileURL)
        super.tearDown()
    }

    // MARK: - Issue #3: PR unit normalization

    // A 90kg set is a genuine PR over a 150lbs set (~68kg) even though 150 >
    // 90 numerically. The database must keep crediting the kg set.
    func testPRKeepsHeavierKgSetOverNumericallyLargerLbsSet() async throws {
        _ = try await database.createStrengthSession(StrengthSessionDraft(
            title: "Kg Session",
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "Bench Press",
                    sets: [StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 90, weightUnit: .kg, reps: 5, rpe: nil)]
                )
            ]
        ))
        _ = try await database.createStrengthSession(StrengthSessionDraft(
            title: "Lbs Session",
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "Bench Press",
                    sets: [StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 150, weightUnit: .lbs, reps: 5, rpe: nil)]
                )
            ]
        ))

        let profile = await database.fetchProfile()
        let pr = try XCTUnwrap(profile.exercisePRs.first { $0.normalizedName == "bench press" })
        XCTAssertEqual(pr.weightUnit, .kg)
        XCTAssertEqual(pr.maxWeight, 90, accuracy: 0.001)
    }

    // Same scenario but the heavier (kg-normalized) set is the lbs one, and
    // it arrives *after* a kg set that is numerically larger but actually
    // lighter. The lbs set should still win once normalized.
    func testPRAwardsLbsSetWhenItIsHeavierAfterNormalization() async throws {
        // Uses an exercise name not present in the seed data (unlike
        // "Deadlift", which the seed profile already has a 120kg PR for).
        _ = try await database.createStrengthSession(StrengthSessionDraft(
            title: "Kg Session",
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "Trap Bar Deadlift",
                    sets: [StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 90, weightUnit: .kg, reps: 5, rpe: nil)]
                )
            ]
        ))
        _ = try await database.createStrengthSession(StrengthSessionDraft(
            title: "Lbs Session",
            workoutDate: Date(),
            exercises: [
                // 250lbs ≈ 113.4kg > 90kg
                StrengthSessionDraft.ExerciseDraft(
                    name: "Trap Bar Deadlift",
                    sets: [StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 250, weightUnit: .lbs, reps: 5, rpe: nil)]
                )
            ]
        ))

        let profile = await database.fetchProfile()
        let pr = try XCTUnwrap(profile.exercisePRs.first { $0.normalizedName == "trap bar deadlift" })
        XCTAssertEqual(pr.weightUnit, .lbs)
        XCTAssertEqual(pr.maxWeight, 250, accuracy: 0.001)
    }

    // Within a single exercise entry, the heaviest *normalized* set among
    // mixed-unit sets must be picked, not the numerically largest.
    func testMaxSetWithinExerciseIsChosenByNormalizedWeight() async throws {
        _ = try await database.createStrengthSession(StrengthSessionDraft(
            title: "Mixed Session",
            workoutDate: Date(),
            exercises: [
                StrengthSessionDraft.ExerciseDraft(
                    name: "Squat",
                    sets: [
                        StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 140, weightUnit: .lbs, reps: 5, rpe: nil), // ~63.5kg
                        StrengthSessionDraft.ExerciseDraft.SetDraft(weight: 100, weightUnit: .kg, reps: 3, rpe: nil)   // heavier
                    ]
                )
            ]
        ))

        let profile = await database.fetchProfile()
        let pr = try XCTUnwrap(profile.exercisePRs.first { $0.normalizedName == "squat" })
        XCTAssertEqual(pr.weightUnit, .kg)
        XCTAssertEqual(pr.maxWeight, 100, accuracy: 0.001)
    }

    // `ExercisePR.maxWeightKg` itself should normalize correctly.
    func testMaxWeightKgComputedProperty() {
        let kgPR = ExercisePR(normalizedName: "x", displayName: "X", maxWeight: 100, weightUnit: .kg, achievedAt: Date())
        let lbsPR = ExercisePR(normalizedName: "y", displayName: "Y", maxWeight: 220.462, weightUnit: .lbs, achievedAt: Date())
        XCTAssertEqual(kgPR.maxWeightKg, 100, accuracy: 0.001)
        XCTAssertEqual(lbsPR.maxWeightKg, 100, accuracy: 0.01)
    }

    // MARK: - Issue #4: volumeDisplay respects unit + rounding

    func testVolumeDisplayKgUnderThousandShowsWholeKg() {
        let vm = ProfileViewModel(profileService: StubProfileService(profile: makeProfile(totalVolumeKg: 999, unit: .kg)))
        vm.profile = makeProfile(totalVolumeKg: 999, unit: .kg)
        XCTAssertEqual(vm.volumeDisplay, "999kg")
    }

    func testVolumeDisplayKgAtThousandShowsOneDecimalTonne() {
        let vm = ProfileViewModel(profileService: StubProfileService(profile: makeProfile(totalVolumeKg: 1000, unit: .kg)))
        vm.profile = makeProfile(totalVolumeKg: 1000, unit: .kg)
        XCTAssertEqual(vm.volumeDisplay, "1.0t")
    }

    // Regression: 1500kg used to truncate/round to "2t" via `%.0f`.
    func testVolumeDisplayKgRoundingIsNotTruncated() {
        let vm = ProfileViewModel(profileService: StubProfileService(profile: makeProfile(totalVolumeKg: 1500, unit: .kg)))
        vm.profile = makeProfile(totalVolumeKg: 1500, unit: .kg)
        XCTAssertEqual(vm.volumeDisplay, "1.5t")
    }

    func testVolumeDisplayLbsUnderThresholdShowsWholeLbs() {
        // 100kg ≈ 220.46 lbs
        let vm = ProfileViewModel(profileService: StubProfileService(profile: makeProfile(totalVolumeKg: 100, unit: .lbs)))
        vm.profile = makeProfile(totalVolumeKg: 100, unit: .lbs)
        XCTAssertEqual(vm.volumeDisplay, "220lbs")
    }

    func testVolumeDisplayLbsRespectsUserPreferenceNotHardcodedKg() {
        // 1000kg ≈ 2204.6 lbs -> must NOT display as "1.0t"; must reflect lbs.
        let vm = ProfileViewModel(profileService: StubProfileService(profile: makeProfile(totalVolumeKg: 1000, unit: .lbs)))
        vm.profile = makeProfile(totalVolumeKg: 1000, unit: .lbs)
        XCTAssertEqual(vm.volumeDisplay, "2.2k lbs")
    }

    private func makeProfile(totalVolumeKg: Double, unit: WeightUnit) -> UserProfile {
        UserProfile(
            id: "user-1",
            displayName: "Test User",
            avatarURL: nil,
            membershipLevel: .free,
            stats: UserStats(workoutsCount: 0, streakDays: 0, totalVolumeKg: totalVolumeKg, prCount: 0),
            preferences: UserPreferences(
                notificationsEnabled: true,
                darkModeEnabled: false,
                weightUnit: unit,
                timezone: "UTC",
                language: .english
            ),
            fitnessGoalSummary: nil,
            exercisePRs: []
        )
    }
}

private struct StubProfileService: ProfileServiceProtocol {
    let profile: UserProfile
    func fetchProfile() async throws -> UserProfile { profile }
    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences { profile.preferences }
    func updateFitnessGoalSummary(_ summary: String) async throws -> String { summary }
    func fetchGoalSpec() async throws -> GoalSpec? { nil }
    func updateGoalSpec(_ spec: GoalSpec) async throws -> GoalSpec { spec }
}
