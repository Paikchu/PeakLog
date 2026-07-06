import Foundation

@main
struct ServiceLayerMockBoundaryTestRunner {
    static func main() throws {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serviceFiles = [
            "PeakLog/Services/ProfileService.swift",
            "PeakLog/Services/WorkoutService.swift",
            "PeakLog/Services/TrainingPlanService.swift"
        ]
        let forbiddenDeclarations = [
            "MockProfileService",
            "MockWorkoutService",
            "MockTrainingPlanService"
        ]

        for path in serviceFiles {
            let fileURL = repoRoot.appendingPathComponent(path)
            let source = try String(contentsOf: fileURL, encoding: .utf8)

            for declaration in forbiddenDeclarations {
                precondition(
                    !source.contains(declaration),
                    "\(declaration) should not be declared in production service layer"
                )
            }
        }

        print("service_layer_mock_boundary_test passed")
    }
}
