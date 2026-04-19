import XCTest
@testable import HoopTrack

final class TelemetryUploadStateTests: XCTestCase {

    func test_nextStateAfterFailure_belowCap_isFailed() {
        let state = TelemetryUploadService.nextStateAfterFailure(
            currentAttempts: 2,
            maxAttempts: HoopTrack.Telemetry.maxUploadAttempts
        )
        XCTAssertEqual(state, .failed)
    }

    func test_nextStateAfterFailure_atCap_isAbandoned() {
        let state = TelemetryUploadService.nextStateAfterFailure(
            currentAttempts: HoopTrack.Telemetry.maxUploadAttempts,
            maxAttempts: HoopTrack.Telemetry.maxUploadAttempts
        )
        XCTAssertEqual(state, .abandoned)
    }

    func test_isEligibleForRetry_pendingAndFailed_areEligible() {
        XCTAssertTrue(TelemetryUploadService.isEligibleForRetry(state: .pending, attempts: 0))
        XCTAssertTrue(TelemetryUploadService.isEligibleForRetry(state: .failed, attempts: 2))
    }

    func test_isEligibleForRetry_uploadingUploadedAbandoned_areNot() {
        XCTAssertFalse(TelemetryUploadService.isEligibleForRetry(state: .uploading, attempts: 1))
        XCTAssertFalse(TelemetryUploadService.isEligibleForRetry(state: .uploaded, attempts: 1))
        XCTAssertFalse(TelemetryUploadService.isEligibleForRetry(state: .abandoned, attempts: 5))
    }

    func test_isEligibleForRetry_failedAtCap_isNotEligible() {
        XCTAssertFalse(TelemetryUploadService.isEligibleForRetry(
            state: .failed,
            attempts: HoopTrack.Telemetry.maxUploadAttempts
        ))
    }
}
