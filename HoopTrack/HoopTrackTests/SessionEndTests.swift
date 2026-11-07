// HoopTrackTests/SessionEndTests.swift
// How a session leaves the screen: a summary when it saved, a short notice
// when nothing was recorded, and never a screen with no way out.
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class SessionEndTests: XCTestCase {

    private var services: AppServices!

    override func setUp() async throws {
        services = AppServices(container: try HoopTrackStore.makeInMemoryContainer())
    }

    override func tearDown() async throws {
        services = nil
    }

    // MARK: - AppState routing

    func test_savedSession_showsSummaryOnceTheCoverHasGone() throws {
        let data = services.dataService
        let session = try data.startSession(drillType: .freeShoot)
        try data.addShot(to: session, result: .make, zone: .paint, shotType: .unknown, courtX: 0.5, courtY: 0.1)
        try data.finaliseSession(session)
        let state = services.appState
        state.activeLaunch = .shooting(nil)

        state.finishSession(with: .saved(SessionResult(session: session, badgeChanges: [])))
        XCTAssertNil(state.activeLaunch)
        XCTAssertNil(state.presentedSummary, "not while the cover is still dismissing")

        state.sessionCoverDismissed()
        XCTAssertEqual(state.presentedSummary?.result.session.id, session.id)
        XCTAssertNil(state.notice)
    }

    func test_discardedSession_explainsWhyThereIsNoSummary() {
        let state = services.appState
        state.activeLaunch = .shooting(nil)
        state.finishSession(with: .discarded)
        state.sessionCoverDismissed()
        XCTAssertNil(state.presentedSummary)
        XCTAssertEqual(state.notice, AppState.discardedNotice)
    }

    func test_closingAfterAFailedSave_orAGame_showsNothing() {
        let state = services.appState
        for end in [SessionEnd.failed, nil] {
            state.finishSession(with: end)
            state.sessionCoverDismissed()
            XCTAssertNil(state.presentedSummary)
            XCTAssertNil(state.notice)
        }
    }

    // MARK: - View models

    func test_shooting_endBeforeTheSessionExists_stillLeaves() async {
        // start() never ran (or failed): ending must not leave the player
        // on a full-screen cover with no way out.
        let model = liveModel()
        let end = await model.end()
        guard case .discarded = end else { return XCTFail("expected .discarded, got \(String(describing: end))") }
        let again = await model.end()
        XCTAssertNil(again, "a second end while the first is done is ignored")
    }

    func test_agility_endWithoutRuns_discardsTheSession() async throws {
        let model = AgilitySessionViewModel(namedDrill: nil, dataService: services.dataService,
                                            coordinator: services.coordinator, haptics: services.hapticService)
        model.start()
        let end = await model.end()
        guard case .discarded = end else { return XCTFail("expected .discarded, got \(String(describing: end))") }
        XCTAssertTrue(try services.dataService.fetchSessions().isEmpty)
    }

    // MARK: - Shots called as the session ends

    func test_shooting_endRightAfterAShot_keepsTheCallStillWaitingForTheNet() async throws {
        // The only shot of the session was an unsure call, waiting up to
        // 0.7 s for the net, when End was tapped. It used to be dropped
        // (and the session thrown away as empty); ShotReplay counted it.
        let model = try await liveModelWithPipeline()
        model.pipeline.handsBack = [detected(.make, confidence: 0.7)]
        let end = await model.vm.end()
        guard case .saved(let result) = end else { return XCTFail("the shot was lost: \(String(describing: end))") }
        XCTAssertEqual(result.session.shotsAttempted, 1)
        XCTAssertEqual(result.session.shotsMade, 1)
        XCTAssertEqual(model.pipeline.stops, 1)
    }

    func test_shooting_aCallArrivingWhileTheSessionEnds_counts_butNotOneAfterwards() async throws {
        let model = try await liveModelWithPipeline()
        let vm = model.vm
        // A call published just before End, delivered while the pipeline stops.
        model.pipeline.whileStopping = { vm.pipelineShotResolved(self.detected(.miss, confidence: 0.95)) }
        model.pipeline.handsBack = [detected(.make, confidence: 0.65)]
        let end = await vm.end()
        guard case .saved(let result) = end else { return XCTFail("expected .saved, got \(String(describing: end))") }
        XCTAssertEqual(result.session.shotsAttempted, 2)

        vm.pipelineShotResolved(detected(.make, confidence: 0.95))   // stale, after the save
        XCTAssertEqual(result.session.shotsAttempted, 2)
    }

    func test_shooting_theCallSettledAsAPauseStarts_counts() async throws {
        // On its first paused frame CVPipeline settles a call still waiting
        // for the net and publishes it; it arrives after isPaused is set.
        let model = try await liveModelWithPipeline()
        model.vm.togglePause()
        XCTAssertTrue(model.pipeline.isPaused)
        model.vm.pipelineShotResolved(detected(.make, confidence: 0.7))
        XCTAssertEqual(model.vm.attempts, 1)
        XCTAssertEqual(model.vm.makes, 1)
    }

    // MARK: - Helpers

    /// Stands in for CVPipeline once the session is running.
    nonisolated private final class FakePipeline: ShotPipelineControl, @unchecked Sendable {
        var isPaused = false
        /// What stop() returns: calls the delegate hadn't been handed.
        var handsBack: [DetectedShot] = []
        /// Runs while stop() is under way.
        var whileStopping: (@MainActor () -> Void)?
        private(set) var stops = 0

        func stop() async -> [DetectedShot] {
            stops += 1
            if let whileStopping { await whileStopping() }
            return handsBack
        }
    }

    private func detected(_ result: ShotResult, confidence: Double) -> DetectedShot {
        DetectedShot(result: result, confidence: confidence, courtX: 0.5, courtY: 0.3, zone: .paint,
                     distanceFt: 8, science: nil, videoOffset: nil)
    }

    /// A started session scoring by hand (no camera in tests), then given a
    /// pipeline as if tracking had started.
    private func liveModelWithPipeline() async throws -> (vm: LiveSessionViewModel, pipeline: FakePipeline) {
        services.cameraService.permissionStatus = .denied
        let model = liveModel()
        await model.start(showDetectionBoxes: false)
        XCTAssertEqual(model.phase, .live)
        let pipeline = FakePipeline()
        model.useForTesting(pipeline: pipeline)
        return (model, pipeline)
    }

    private func liveModel() -> LiveSessionViewModel {
        LiveSessionViewModel(namedDrill: nil, dataService: services.dataService,
                             coordinator: services.coordinator, camera: services.cameraService,
                             haptics: services.hapticService)
    }
}
