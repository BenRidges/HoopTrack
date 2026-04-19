import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class TelemetryUploadModelTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: TelemetryUpload.self, configurations: config)
    }

    func test_defaultState_isPending() throws {
        let id = UUID()
        let upload = TelemetryUpload(
            sessionID: id, sessionKind: .training,
            frameCount: 500, totalBytes: 25_000_000
        )
        XCTAssertEqual(upload.state, .pending)
        XCTAssertEqual(upload.sessionKind, .training)
        XCTAssertEqual(upload.attemptCount, 0)
        XCTAssertNil(upload.lastAttemptAt)
        XCTAssertNil(upload.remoteBucketPath)
    }

    func test_stateTransitions_persist() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let upload = TelemetryUpload(
            sessionID: UUID(), sessionKind: .game,
            frameCount: 700, totalBytes: 30_000_000
        )
        ctx.insert(upload)
        try ctx.save()

        upload.state = .uploading
        upload.lastAttemptAt = .now
        upload.attemptCount = 1
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<TelemetryUpload>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.state, .uploading)
        XCTAssertEqual(fetched.first?.attemptCount, 1)
    }
}
