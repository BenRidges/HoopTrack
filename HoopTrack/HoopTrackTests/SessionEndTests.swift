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

    private func liveModel() -> LiveSessionViewModel {
        LiveSessionViewModel(namedDrill: nil, dataService: services.dataService,
                             coordinator: services.coordinator, camera: services.cameraService,
                             haptics: services.hapticService)
    }
}
