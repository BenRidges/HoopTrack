// HoopTrackTests/LiveShotCorrectionTests.swift
// The live Make / Miss buttons right after an automatic call: the other
// result changes that call (tapping Make on a wrong miss used to log a
// second shot); anything else logs a shot as before.
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class LiveShotCorrectionTests: XCTestCase {

    private var services: AppServices!

    override func setUp() async throws {
        services = AppServices(container: try HoopTrackStore.makeInMemoryContainer())
    }

    override func tearDown() async throws {
        services = nil
    }

    func test_otherResultRightAfterACall_changesTheCall() async throws {
        let vm = try await liveModel()
        vm.pipelineShotResolved(detected(.miss, confidence: 0.95))
        vm.logManual(.make)

        XCTAssertEqual(vm.attempts, 1, "a correction, not a second shot")
        XCTAssertEqual(vm.makes, 1)
        let shot = try XCTUnwrap(lastShot(vm))
        XCTAssertEqual(shot.result, .make)
        XCTAssertTrue(shot.isUserCorrected)
        XCTAssertFalse(shot.needsReview)
        XCTAssertEqual(vm.lastShot?.corrected, true)
    }

    func test_aFlaggedCallChanged_losesItsFlag() async throws {
        let vm = try await liveModel()
        vm.pipelineShotResolved(detected(.make, confidence: 0.5))   // flagged "Check"
        XCTAssertTrue(try XCTUnwrap(lastShot(vm)).needsReview)
        vm.logManual(.miss)
        XCTAssertEqual(vm.attempts, 1)
        XCTAssertFalse(try XCTUnwrap(lastShot(vm)).needsReview)
    }

    func test_sameResult_logsAnotherShot() async throws {
        let vm = try await liveModel()
        vm.pipelineShotResolved(detected(.make, confidence: 0.95))
        vm.logManual(.make)
        XCTAssertEqual(vm.attempts, 2)
        XCTAssertEqual(vm.makes, 2)
    }

    func test_onlyOneChangePerCall() async throws {
        // After the change, the window is closed: a second tap is a shot.
        let vm = try await liveModel()
        vm.pipelineShotResolved(detected(.miss, confidence: 0.95))
        vm.logManual(.make)
        vm.logManual(.miss)
        XCTAssertEqual(vm.attempts, 2)
        XCTAssertEqual(vm.makes, 1)
    }

    func test_afterTheWindow_logsAShot() async throws {
        let vm = try await liveModel()
        var now = Date.now
        vm.clock = { now }
        vm.pipelineShotResolved(detected(.miss, confidence: 0.95))
        now += HoopTrack.CV.correctionWindowSec + 1
        vm.logManual(.make)
        XCTAssertEqual(vm.attempts, 2)
        XCTAssertEqual(try XCTUnwrap(vm.session?.orderedShots.first).result, .miss)
    }

    func test_onceTheNextShotStarts_logsAShot() async throws {
        let vm = try await liveModel()
        vm.pipelineShotResolved(detected(.miss, confidence: 0.95))
        vm.pipelineShotStarted()
        vm.logManual(.make)
        XCTAssertEqual(vm.attempts, 2)
    }

    func test_aShotLoggedByHand_isNeverChangedByATap() async throws {
        let vm = try await liveModel()
        vm.logManual(.miss)
        vm.logManual(.make)
        XCTAssertEqual(vm.attempts, 2)
        XCTAssertEqual(vm.makes, 1)
    }

    func test_afterUndo_logsAShot() async throws {
        let vm = try await liveModel()
        vm.pipelineShotResolved(detected(.make, confidence: 0.95))
        vm.pipelineShotResolved(detected(.miss, confidence: 0.95))
        vm.undoLast()
        vm.logManual(.miss)
        XCTAssertEqual(vm.attempts, 2)
        XCTAssertEqual(vm.makes, 1)
    }

    // MARK: - Helpers

    /// A started session (no camera in tests, so it scores by hand) that
    /// then gets the tracker's calls through the pipeline delegate.
    private func liveModel() async throws -> LiveSessionViewModel {
        services.cameraService.permissionStatus = .denied
        let vm = LiveSessionViewModel(namedDrill: nil, dataService: services.dataService,
                                      coordinator: services.coordinator, camera: services.cameraService,
                                      haptics: services.hapticService)
        await vm.start(showDetectionBoxes: false)
        XCTAssertEqual(vm.phase, .live)
        return vm
    }

    private func lastShot(_ vm: LiveSessionViewModel) -> ShotRecord? {
        vm.session?.orderedShots.last
    }

    private func detected(_ result: ShotResult, confidence: Double) -> DetectedShot {
        DetectedShot(result: result, confidence: confidence, courtX: 0.5, courtY: 0.3, zone: .paint,
                     distanceFt: 8, science: nil, videoOffset: nil)
    }
}
