import XCTest
@testable import PeakLog

@MainActor
final class SaveSheetErrorHandlingTests: XCTestCase {
    func testGoalSpecSavePropagatesFailureToKeepSheetOpen() async {
        let viewModel = ProfileViewModel(profileService: FailingSaveProfileService())

        do {
            let _: GoalSpec = try await viewModel.saveGoalSpec(.default)
            XCTFail("saveGoalSpec should propagate the persistence error")
        } catch {
            XCTAssertEqual((error as NSError).code, 63)
            XCTAssertNil(viewModel.goalSpec)
        }
    }
}

private struct FailingSaveProfileService: ProfileServiceProtocol {
    func fetchProfile() async throws -> UserProfile { fatalError("unused") }
    func updatePreferences(_ prefs: UpdatePreferencesRequest) async throws -> UserPreferences { fatalError("unused") }
    func updateFitnessGoalSummary(_ summary: String) async throws -> String { fatalError("unused") }
    func fetchGoalSpec() async throws -> GoalSpec? { nil }
    func updateGoalSpec(_ spec: GoalSpec) async throws -> GoalSpec {
        throw NSError(domain: "SaveSheetErrorHandlingTests", code: 63)
    }
}
