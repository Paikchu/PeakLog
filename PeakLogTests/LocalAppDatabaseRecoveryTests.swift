import XCTest
@testable import PeakLog

final class LocalAppDatabaseRecoveryTests: XCTestCase {
    func testUnreadableStateIsPreservedAndBlocksCloudSync() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-recovery-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("state.json")
        let corruptData = Data("not valid local state".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try corruptData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = LocalAppDatabase(fileURL: fileURL)

        let status = await database.localStateRecoveryStatus()
        let isCloudSyncSafe = await database.isCloudSyncSafe()
        let preservedData = try Data(contentsOf: fileURL)
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("state.recovery-") && $0.hasSuffix(".json") }

        XCTAssertEqual(status, .recoveryRequired)
        XCTAssertFalse(isCloudSyncSafe)
        XCTAssertEqual(preservedData, corruptData)
        XCTAssertEqual(backupNames.count, 1)
    }
}
