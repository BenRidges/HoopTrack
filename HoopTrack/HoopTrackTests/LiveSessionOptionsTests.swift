// HoopTrackTests/LiveSessionOptionsTests.swift
// The session options in a live shooting session: calls said out loud,
// setup tips, drill steps, a timed drill waiting for its first shot,
// pausing when nobody's shooting, and a best to beat. Plus "Go again".
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class LiveSessionOptionsTests: XCTestCase {

    private var services: AppServices!
    private var announcer: RecordingAnnouncer!
    private var now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() async throws {
        services = AppServices(container: try HoopTrackStore.makeInMemoryContainer())
        announcer = RecordingAnnouncer()
        UserDefaults.standard.removeObject(forKey: AppPreferences.Key.goAgain)
    }

    override func tearDown() async throws {
        services = nil
        announcer = nil
    }

    // MARK: - Calls

    func test_callsAndCorrections_goToTheAnnouncer() async throws {
        let vm = try await liveModel()
        XCTAssertEqual(announcer.mode, .voice)
        vm.pipelineShotResolved(detected(.miss))
        vm.logManual(.make)                         // changes the call
        XCTAssertEqual(announcer.shots.map(\.result), [.miss, .make])
        XCTAssertEqual(announcer.shots.map(\.corrected), [false, true])
        XCTAssertEqual(announcer.shots.last?.makes, 1)
        XCTAssertEqual(SessionAnnouncer.shotPhrase(.make, makes: 7, attempts: 10, corrected: false), "Make. 7 for 10.")
        XCTAssertEqual(SessionAnnouncer.shotPhrase(.miss, makes: 6, attempts: 10, corrected: true),
                       "Changed to miss. 6 for 10.")
    }

    // MARK: - Setup tips

    func test_setupTip_showsOnceSettled_andGoesAtTheFirstShot() async throws {
        let vm = try await liveModel(tracking: true)
        let tooClose = CGRect(x: 0.4, y: 0.4, width: 0.16, height: 0.12)
        vm.pipelineHoopChanged(.tracking(hoopRect: tooClose))
        XCTAssertNil(vm.setupAdvice, "not on the first glimpse")
        now += 1.5
        vm.pipelineHoopChanged(.tracking(hoopRect: tooClose))
        XCTAssertEqual(vm.setupAdvice, .tooClose)
        XCTAssertEqual(announcer.said.first, "Hoop found. " + SetupAdvice.tooClose.spoken)

        vm.pipelineShotStarted()
        XCTAssertNil(vm.setupAdvice, "tips stop once shooting starts")
    }

    func test_setupTipsOff_justSaysTheHoopWasFound() async throws {
        var options = SessionOptions()
        options.setupCoach = false
        let vm = try await liveModel(options: options, tracking: true)
        vm.pipelineHoopChanged(.tracking(hoopRect: CGRect(x: 0.4, y: 0.4, width: 0.16, height: 0.12)))
        now += 2
        vm.pipelineHoopChanged(.tracking(hoopRect: CGRect(x: 0.4, y: 0.4, width: 0.16, height: 0.12)))
        XCTAssertNil(vm.setupAdvice)
        XCTAssertEqual(announcer.said, ["Hoop found. Start shooting."])
    }

    // MARK: - Drill steps

    func test_aroundTheArc_movesYouOnAfterFiveShots() async throws {
        let vm = try await liveModel(drill: .aroundTheArc)
        XCTAssertEqual(vm.drillProgress?.spot, "Right corner")
        for result in [ShotResult.make, .make, .miss, .make, .miss] { vm.logManual(result) }
        XCTAssertEqual(vm.drillProgress?.spot, "Right wing")
        XCTAssertEqual(vm.drillCue?.text, "Move to the right wing")
        XCTAssertEqual(announcer.said.last, "3 of 5. Move to the right wing.")

        vm.undoLast()
        XCTAssertEqual(vm.drillProgress?.spot, "Right corner", "undo steps back")
    }

    func test_drillGuidanceOff_showsNoSteps() async throws {
        let vm = try await liveModel(options: .none, drill: .aroundTheArc)
        XCTAssertNil(vm.drillProgress)
    }

    // MARK: - Timed drills

    func test_timedDrill_clockWaitsForTheFirstShot() async throws {
        let vm = try await liveModel(drill: .fiveMinEndurance)
        XCTAssertTrue(vm.isClockWaiting)
        now += 60                                   // walking to the court
        XCTAssertEqual(vm.activeElapsed(), 0)
        vm.pipelineShotStarted()
        XCTAssertFalse(vm.isClockWaiting)
        now += 10
        XCTAssertEqual(vm.activeElapsed(), 10, accuracy: 0.01)
    }

    func test_timedDrill_withoutTheOption_clockRunsFromTheStart() async throws {
        let vm = try await liveModel(options: .none, drill: .fiveMinEndurance)
        XCTAssertFalse(vm.isClockWaiting)
        now += 60
        XCTAssertEqual(vm.activeElapsed(), 60, accuracy: 0.01)
    }

    // MARK: - Breaks

    func test_twoQuietMinutes_pauseTheClock_andAShotCarriesOn() async throws {
        let vm = try await liveModel()
        vm.logManual(.make)
        now += 30
        vm.checkIdle()
        XCTAssertFalse(vm.isIdle)
        now += 100                                  // 130 s since the shot
        vm.checkIdle()
        XCTAssertTrue(vm.isIdle)
        XCTAssertEqual(vm.activeElapsed(), 0, accuracy: 0.01, "the quiet minutes don't count")
        now += 300
        XCTAssertEqual(vm.activeElapsed(), 0, accuracy: 0.01)

        vm.pipelineShotStarted()
        XCTAssertFalse(vm.isIdle)
        now += 5
        XCTAssertEqual(vm.activeElapsed(), 5, accuracy: 0.01)
    }

    func test_aLongBreak_asks_thenEndsTheSession() async throws {
        let vm = try await liveModel()
        vm.logManual(.make)
        now += HoopTrack.Session.idlePauseSec
        vm.checkIdle()
        now += HoopTrack.Session.idleAskSec - HoopTrack.Session.idlePauseSec
        vm.checkIdle()
        XCTAssertTrue(vm.idlePrompt)
        XCTAssertFalse(vm.idleTimedOut)

        vm.noteActivity()                           // Keep going
        XCTAssertFalse(vm.isIdle)
        XCTAssertFalse(vm.idlePrompt)

        now += HoopTrack.Session.idleEndSec
        vm.checkIdle()
        XCTAssertTrue(vm.idleTimedOut)
    }

    func test_breaksOff_neverPause() async throws {
        let vm = try await liveModel(options: .none)
        now += 3600
        vm.checkIdle()
        XCTAssertFalse(vm.isIdle)
    }

    // MARK: - Best to beat

    func test_aDrillBest_isTheTarget_andANewBestIsSaidOnce() async throws {
        let data = services.dataService
        let old = try data.startSession(drillType: .freeShoot, namedDrill: .fiveMinEndurance)
        for _ in 0..<2 {
            try data.addShot(to: old, result: .make, zone: .paint, shotType: .unknown, courtX: 0.5, courtY: 0.1)
        }
        try data.finaliseSession(old)

        let vm = try await liveModel(drill: .fiveMinEndurance)
        XCTAssertEqual(vm.target, .makes(best: 2))
        for _ in 0..<4 { vm.logManual(.make) }
        XCTAssertEqual(announcer.said.filter { $0 == "New best!" }.count, 1)
    }

    // MARK: - Go again

    func test_goAgain_startsTheSameSessionOnceTheSummaryHasGone() throws {
        let data = services.dataService
        let session = try data.startSession(drillType: .freeShoot, namedDrill: .aroundTheArc)
        try data.addShot(to: session, result: .make, zone: .paint, shotType: .unknown, courtX: 0.5, courtY: 0.1)
        try data.finaliseSession(session)
        let state = services.appState
        state.activeLaunch = .shooting(.aroundTheArc)
        state.finishSession(with: .saved(SessionResult(session: session, badgeChanges: [])))
        state.sessionCoverDismissed()
        let again = try XCTUnwrap(state.presentedSummary?.again)
        XCTAssertEqual(again, .shooting(.aroundTheArc))

        state.goAgain(again)
        XCTAssertNil(state.presentedSummary)
        XCTAssertNil(state.activeLaunch, "not while the summary is still going")
        state.summaryDismissed()
        XCTAssertEqual(state.activeLaunch, .shooting(.aroundTheArc))
    }

    func test_goAgainOff_hidesIt() throws {
        UserDefaults.standard.set(false, forKey: AppPreferences.Key.goAgain)
        defer { UserDefaults.standard.removeObject(forKey: AppPreferences.Key.goAgain) }
        let data = services.dataService
        let session = try data.startSession(drillType: .freeShoot)
        try data.addShot(to: session, result: .make, zone: .paint, shotType: .unknown, courtX: 0.5, courtY: 0.1)
        try data.finaliseSession(session)
        let state = services.appState
        state.activeLaunch = .shooting(nil)
        state.finishSession(with: .saved(SessionResult(session: session, badgeChanges: [])))
        state.sessionCoverDismissed()
        XCTAssertNotNil(state.presentedSummary)
        XCTAssertNil(state.presentedSummary?.again)
        state.summaryDismissed()
        XCTAssertNil(state.activeLaunch)
    }

    // MARK: - Helpers

    /// A started session scoring by hand (no camera in tests); `tracking`
    /// runs it on a stand-in pipeline so hoop updates count.
    private func liveModel(options: SessionOptions = SessionOptions(), drill: NamedDrill? = nil,
                           tracking: Bool = false) async throws -> LiveSessionViewModel {
        services.cameraService.permissionStatus = .denied
        let vm = LiveSessionViewModel(namedDrill: drill, dataService: services.dataService,
                                      coordinator: services.coordinator, camera: services.cameraService,
                                      haptics: services.hapticService, options: options, announcer: announcer)
        vm.clock = { [unowned self] in self.now }
        await vm.start(showDetectionBoxes: false)
        XCTAssertEqual(vm.phase, .live)
        if tracking { vm.useForTesting(pipeline: IdlePipeline()) }
        return vm
    }

    private func detected(_ result: ShotResult) -> DetectedShot {
        DetectedShot(result: result, confidence: 0.95, courtX: 0.5, courtY: 0.3, zone: .paint,
                     distanceFt: 8, science: nil, videoOffset: nil)
    }
}

/// Keeps what a session asked to have said.
@MainActor
private final class RecordingAnnouncer: SessionAnnouncing {
    deinit {} // Keep: see "Explicit deinit" in CLAUDE.md

    struct Call { let result: ShotResult; let makes: Int; let attempts: Int; let corrected: Bool }
    private(set) var mode: ShotCallMode?
    private(set) var shots: [Call] = []
    private(set) var said: [String] = []

    func begin(mode: ShotCallMode) { self.mode = mode }
    func shot(_ result: ShotResult, makes: Int, attempts: Int, corrected: Bool) {
        shots.append(Call(result: result, makes: makes, attempts: attempts, corrected: corrected))
    }
    func say(_ text: String) { said.append(text) }
    func end() {}
}

/// A pipeline that never calls anything.
nonisolated private final class IdlePipeline: ShotPipelineControl, @unchecked Sendable {
    var isPaused = false
    func stop() async -> [DetectedShot] { [] }
}
