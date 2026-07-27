import XCTest
@testable import PeakLog

final class PlanReplanServiceTests: XCTestCase {
    override func tearDown() {
        SDKRecordingURLProtocol.reset()
        super.tearDown()
    }

    func testReplannedOutcome() async throws {
        SDKRecordingURLProtocol.enqueueJSON(
            #"{"results":[{"status":"replanned","replannedDates":["2026-07-29"],"reason":null,"error":null}]}"#
        )

        let outcome = try await makeService().requestReplan(userId: "user-1", signal: .skipToday)

        XCTAssertEqual(outcome, .replanned(["2026-07-29"]))
        XCTAssertTrue(SDKRecordingURLProtocol.requests.last?.url?.path
            .hasSuffix("/functions/v1/generate-weekly-plan") == true)
    }

    func testNoChangeOutcomes() async throws {
        for status in ["no_op", "skipped", "rate_limited"] {
            SDKRecordingURLProtocol.enqueueJSON(
                #"{"results":[{"status":"\#(status)","replannedDates":null,"reason":"unchanged","error":null}]}"#
            )
            let outcome = try await makeService().requestReplan(
                userId: "user-1",
                signal: .skipToday
            )
            XCTAssertEqual(outcome, .noChange(reason: "unchanged"))
        }
    }

    func testFailedAndUnknownOutcomes() async throws {
        for status in ["failed", "unexpected"] {
            SDKRecordingURLProtocol.enqueueJSON(
                #"{"results":[{"status":"\#(status)","replannedDates":null,"reason":null,"error":"generation failed"}]}"#
            )
            let outcome = try await makeService().requestReplan(
                userId: "user-1",
                signal: .skipToday
            )
            XCTAssertEqual(outcome, .failed(reason: "generation failed"))
        }
    }

    func testTokenFailureSendsNoRequest() async {
        let service = makeService(tokenProvider: StubTokenProvider(.failure))

        await assertCloudError(.unauthorized) {
            _ = try await service.requestReplan(userId: "user-1", signal: .skipToday)
        }
        XCTAssertTrue(SDKRecordingURLProtocol.requests.isEmpty)
    }

    func testHTTPAndDecodeErrorsAreMapped() async {
        for status in [401, 403] {
            SDKRecordingURLProtocol.enqueue(status: status, body: Data("denied".utf8))
            await assertCloudError(.unauthorized) {
                _ = try await makeService().requestReplan(
                    userId: "user-1",
                    signal: .skipToday
                )
            }
        }

        SDKRecordingURLProtocol.enqueue(status: 500, body: Data("failure".utf8))
        await assertCloudError(.remote(code: "500", message: "failure")) {
            _ = try await makeService().requestReplan(userId: "user-1", signal: .skipToday)
        }

        SDKRecordingURLProtocol.enqueueJSON(#"{"unexpected":true}"#)
        do {
            _ = try await makeService().requestReplan(userId: "user-1", signal: .skipToday)
            XCTFail("Expected decode failure")
        } catch let error as CloudError {
            guard case .remote(let code, _) = error else {
                XCTFail("Expected remote decode error, got \(error)")
                return
            }
            XCTAssertEqual(code, "decode")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeService(
        tokenProvider: StubTokenProvider = StubTokenProvider()
    ) -> PlanReplanService {
        PlanReplanService(
            client: SupabaseSDKTestClient.make(),
            tokenProvider: tokenProvider
        )
    }

    private func assertCloudError(
        _ expected: CloudError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as CloudError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
