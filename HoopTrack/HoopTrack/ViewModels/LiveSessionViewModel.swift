// LiveSessionViewModel.swift
// Owns one live shooting session: camera, CV pipeline, recording, timer,
// shot log and the hand-off to SessionFinalizationCoordinator.
//
// Ending a session stops the pipeline and finishes the video *before*
// saving, so the summary has the video and the camera isn't left running
// (and recording) behind it.

import Foundation
import Combine
import CoreGraphics
import CoreMedia
import UIKit
import AVFoundation

@MainActor
final class LiveSessionViewModel: ObservableObject, ShotPipelineDelegate {

    enum Phase: Equatable {
        case starting
        case live
        case ending
    }

    /// Where the hoop tracker is, for the HUD.
    enum HoopStatus: Equatable {
        case manual        // no model bundled — buttons only
        case searching     // never seen the hoop yet
        case tracking
        case lost
    }

    // MARK: Published

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var hoopStatus: HoopStatus = .searching
    @Published private(set) var hoopRect: CGRect?
    @Published private(set) var ballBox: CGRect?
    @Published private(set) var isPaused = false
    @Published private(set) var shotInFlight = false
    @Published private(set) var recentResults: [ShotResult] = []
    /// Changes on every logged shot so the HUD can flash.
    @Published private(set) var lastShot: ShotFlash?
    /// Set when a timed drill runs out; the view ends the session.
    @Published private(set) var timeIsUp = false
    @Published private(set) var makes = 0
    @Published private(set) var attempts = 0
    @Published var skippedHoopSearch = false
    @Published var errorMessage: String?

    var fgPercent: Double? { attempts > 0 ? Double(makes) / Double(attempts) * 100 : nil }
    let namedDrill: NamedDrill?
    var timeLimit: TimeInterval? { namedDrill?.timeLimitSec }

    // MARK: Playoffs

    /// The run as of the last shot; nil outside a playoff sitting.
    @Published private(set) var playoff: PlayoffRun?
    /// The latest game or series result, for the HUD's card.
    @Published private(set) var playoffMoment: PlayoffMoment?
    /// Where to take comeback shots: the player's weakest zone, if known.
    private(set) var comebackZone: CourtZone?
    let playoffSeriesID: UUID?
    private var playoffSeries: PlayoffSeries?
    /// The run before this sitting's first shot.
    private var playoffBase: PlayoffRun?
    private var momentCounter = 0

    // MARK: Dependencies

    private let dataService: DataService
    private let coordinator: SessionFinalizationCoordinator
    private let camera: CameraService
    private let haptics: HapticService
    private var session: TrainingSession?
    private var pipeline: CVPipeline?
    private var recorder: SessionRecorder?
    private var shotCounter = 0
    private var flightTimeout: Task<Void, Never>?
    private var limitWatcher: Task<Void, Never>?
    private var courtType: CourtType = .nba
    private var showDetectionBoxes = false

    // Active-time clock (pauses excluded).
    private var runningSince: Date?
    private var accumulated: TimeInterval = 0
    private var lastAnnouncement = Date.distantPast

    init(namedDrill: NamedDrill?,
         playoffSeriesID: UUID? = nil,
         dataService: DataService,
         coordinator: SessionFinalizationCoordinator,
         camera: CameraService,
         haptics: HapticService) {
        self.namedDrill = namedDrill
        self.playoffSeriesID = playoffSeriesID
        self.dataService = dataService
        self.coordinator = coordinator
        self.camera = camera
        self.haptics = haptics
    }

    // MARK: - Lifecycle

    func start(showDetectionBoxes: Bool) async {
        guard phase == .starting, session == nil else { return }
        self.showDetectionBoxes = showDetectionBoxes

        if camera.permissionStatus == .notDetermined {
            await camera.requestPermission()
        }

        let profile = try? dataService.fetchOrCreateProfile()
        courtType = profile?.preferredCourtType ?? .nba
        let series = playoffSeriesID.flatMap { dataService.playoffSeries(id: $0) }
        do {
            session = try dataService.startSession(drillType: .freeShoot,
                                                   namedDrill: namedDrill,
                                                   courtType: courtType,
                                                   playoffSeriesID: series?.id)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if let series {
            let base = dataService.playoffRun(for: series)
            playoffSeries = series
            playoffBase = base
            playoff = base
            comebackZone = PlayoffRun.weakestZone(dataService.recentShotZones())
        }

        beginClock()
        if camera.permissionStatus == .authorized {
            startTracking()
        } else {
            hoopStatus = .manual
        }
    }

    /// Starts tracking if camera access arrives mid-session (turned on in
    /// Settings while the session was scoring by hand).
    func cameraPermissionChanged() {
        guard phase == .live, pipeline == nil, camera.permissionStatus == .authorized else { return }
        startTracking()
    }

    private func startTracking() {
        guard let session, pipeline == nil else { return }
        camera.configureSession(mode: .rear, orientation: .landscape)
        camera.startSession()

        let detector = BallDetectorFactory.make(BallDetectorFactory.active)
        hoopStatus = detector == nil ? .manual : .searching

        let camera = self.camera
        let pipeline = CVPipeline(detector: detector,
                                  threePointDistanceFt: courtType.threePointDistanceFt,
                                  fieldOfView: { camera.horizontalFieldOfView })
        let recorder = SessionRecorder(sessionID: session.id)
        pipeline.recorder = recorder
        pipeline.publishesBall = showDetectionBoxes
        pipeline.isPaused = isPaused
        // CV-A — local detection log, only when the user has opted in to
        // sharing and is signed in (signed out, nothing could send it).
        if AppPreferences.shareTrainingData,
           (try? dataService.fetchOrCreateProfile())?.supabaseUserID != nil,
           let logger = try? DetectionLogger(sessionID: session.id) {
            pipeline.attachTelemetry(logger: logger)
        }
        pipeline.start(framePublisher: camera.framePublisher, delegate: self)
        self.pipeline = pipeline
        self.recorder = recorder
    }

    /// Called if the view goes away without `end()` (e.g. the system dismissed it).
    /// Keeps what was logged, with its video; throws away an empty session.
    func tearDown() {
        guard phase != .ending else { return }
        phase = .ending
        let active = activeElapsed()
        limitWatcher?.cancel()
        flightTimeout?.cancel()
        pipeline?.stop()
        pipeline = nil
        camera.stopSession()
        let recorder = self.recorder
        self.recorder = nil
        guard let session else { return }

        if attempts == 0 {
            dataService.discardSession(session)
            Task { if let url = await recorder?.finish() { try? FileManager.default.removeItem(at: url) } }
        } else {
            let series = playoffSeries
            Task { [coordinator, dataService] in
                session.videoFileName = await recorder?.finish()?.lastPathComponent
                _ = try? await coordinator.finaliseSession(session, activeDuration: active)
                if let series { dataService.refreshPlayoff(series) }
            }
        }
    }

    func togglePause() {
        isPaused.toggle()
        pipeline?.isPaused = isPaused
        if isPaused {
            if let since = runningSince { accumulated += Date.now.timeIntervalSince(since) }
            runningSince = nil
            shotInFlight = false
        } else {
            runningSince = .now
        }
        haptics.tap()
    }

    /// Finishes the session. Returns nil when nothing worth keeping happened.
    func end() async -> SessionResult? {
        guard phase != .ending, let session else { return nil }
        phase = .ending
        let active = activeElapsed()
        limitWatcher?.cancel()
        flightTimeout?.cancel()
        pipeline?.stop()
        pipeline = nil
        let videoURL = await finishRecording()
        camera.stopSession()

        // Nothing logged and barely started: don't clutter history.
        if attempts == 0 && active < 20 {
            if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
            dataService.discardSession(session)
            return nil
        }

        session.videoFileName = videoURL?.lastPathComponent
        do {
            let result = try await coordinator.finaliseSession(session, activeDuration: active)
            if let playoffSeries { dataService.refreshPlayoff(playoffSeries) }
            haptics.milestone()
            return result
        } catch {
            errorMessage = error.localizedDescription
            phase = .live
            return nil
        }
    }

    // MARK: - Clock

    func activeElapsed(at date: Date = .now) -> TimeInterval {
        accumulated + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    private func beginClock() {
        runningSince = .now
        phase = .live
        guard let limit = timeLimit else { return }
        limitWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if self.activeElapsed() >= limit {
                    self.haptics.longPress()
                    self.timeIsUp = true
                    return
                }
            }
        }
    }

    // MARK: - Manual logging & corrections

    func logManual(_ result: ShotResult) {
        record(result: result, zone: .unknown, courtX: 0.5, courtY: 0.5,
               science: nil, videoOffset: nil, detectionConfidence: nil)
    }

    /// Removes the most recent shot (wrong call, or a shot that never happened).
    func undoLast() {
        guard let session, let last = session.orderedShots.last else { return }
        dataService.deleteShot(last)
        refreshCounts()
        updatePlayoff(announce: false)
        haptics.tap()
    }

    func dismissPlayoffMoment() {
        playoffMoment = nil
    }

    // MARK: - ShotPipelineDelegate

    func pipelineHoopChanged(_ state: CalibrationState) {
        guard hoopStatus != .manual else { return }
        switch state {
        case .looking:  hoopStatus = .searching
        case .tracking: hoopStatus = .tracking
        case .lost:     hoopStatus = .lost
        }
        let wasFound = hoopRect != nil
        hoopRect = state.hoopRect
        if !wasFound, state.isTracking {
            haptics.shotDetected()
            UIAccessibility.post(notification: .announcement, argument: "Hoop found. Start shooting.")
        }
    }

    func pipelineBallMoved(_ box: CGRect?) {
        ballBox = box
    }

    func pipelineShotStarted() {
        guard !isPaused else { return }
        shotInFlight = true
        flightTimeout?.cancel()
        flightTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.shotInFlight = false
        }
    }

    func pipelineShotResolved(_ shot: DetectedShot) {
        shotInFlight = false
        guard !isPaused, phase == .live else { return }
        record(result: shot.result, zone: shot.zone, courtX: shot.courtX, courtY: shot.courtY,
               science: shot.science, videoOffset: shot.videoOffset,
               detectionConfidence: shot.confidence)
    }

    // MARK: - Private

    private func record(result: ShotResult, zone: CourtZone, courtX: Double, courtY: Double,
                        science: ShotScienceMetrics?, videoOffset: Double?,
                        detectionConfidence: Double?) {
        guard let session, phase == .live else { return }
        do {
            try dataService.addShot(to: session, result: result, zone: zone, shotType: .unknown,
                                    courtX: courtX, courtY: courtY, science: science,
                                    videoOffset: videoOffset ?? recordingOffsetNow(),
                                    needsReview: (detectionConfidence ?? 1) < HoopTrack.CV.lowConfidence,
                                    detectionConfidence: detectionConfidence)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        refreshCounts()
        shotCounter += 1
        lastShot = ShotFlash(result: result, id: shotCounter)
        result == .make ? haptics.makeMade() : haptics.missMade()
        announce(result)
        updatePlayoff(announce: true)
    }

    /// Replays this sitting's shots on top of the run as it stood, so an
    /// undo un-decides a game as cleanly as a shot decides one.
    private func updatePlayoff(announce: Bool) {
        guard let base = playoffBase, let session else { return }
        var run = base
        var event: PlayoffEvent?
        for shot in session.orderedShots { event = run.record(shot.result) }
        playoff = run
        guard announce, let event else {
            if !announce { playoffMoment = nil }
            return
        }
        momentCounter += 1
        playoffMoment = PlayoffMoment(event: event, id: momentCounter)
        switch event {
        case .seriesWon, .champion, .comebackComplete: haptics.milestone()
        case .eliminated:                              haptics.longPress()
        case .gameWon, .gameLost:                      break
        }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: PlayoffMoment.spoken(event, run: run))
        }
    }

    private func refreshCounts() {
        guard let session else { return }
        makes = session.shotsMade
        attempts = session.shotsAttempted
        recentResults = Array(session.orderedShots.suffix(8).map(\.result))
    }

    /// Offset into the video for manually logged shots. Capture timestamps
    /// run on the host clock, so "now" on that clock lines up with the file.
    private func recordingOffsetNow() -> Double? {
        guard let start = recorder?.startTime else { return nil }
        return max(0, CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - start)
    }

    private func finishRecording() async -> URL? {
        let recorder = self.recorder
        self.recorder = nil
        return await recorder?.finish()
    }

    private func announce(_ result: ShotResult) {
        guard UIAccessibility.isVoiceOverRunning,
              Date.now.timeIntervalSince(lastAnnouncement) >= 2 else { return }
        lastAnnouncement = .now
        let word = result == .make ? "Make" : "Miss"
        UIAccessibility.post(notification: .announcement, argument: "\(word). \(makes) for \(attempts).")
    }
}

/// A playoff result to show on the HUD.
struct PlayoffMoment: Equatable, Identifiable {
    let event: PlayoffEvent
    let id: Int

    static func spoken(_ event: PlayoffEvent, run: PlayoffRun) -> String {
        switch event {
        case .gameWon:          return "Game won. Series \(run.wins) to \(run.losses)."
        case .gameLost:         return "Game lost. Series \(run.wins) to \(run.losses)."
        case .seriesWon(let round, _):
            return "\(PlayoffRun.roundName(round)) won. On to the \(run.roundName.lowercased())."
        case .eliminated:       return "Eliminated. Make \(run.comebackTarget) to earn another shot."
        case .champion:         return "Champion!"
        case .comebackComplete: return "You're back in. The series starts again at zero all."
        }
    }
}

struct ShotFlash: Equatable {
    let result: ShotResult
    let id: Int
}
