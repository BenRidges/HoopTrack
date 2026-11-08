// LiveSessionViewModel.swift
// Owns one live shooting session: camera, CV pipeline, recording, timer,
// shot log and the hand-off to SessionFinalizationCoordinator.
//
// Ending a session stops the pipeline and finishes the video *before*
// saving, so the summary has the video and the camera isn't left running
// (and recording) behind it. Calls the pipeline made before the end — one
// still waiting for the net check, or one still on its way to the main
// actor — are recorded first, so tapping End right after a shot keeps it.

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
    private(set) var session: TrainingSession?
    private var pipeline: (any ShotPipelineControl)?
    /// While the session is ending and waits for the pipeline to stop: the
    /// calls it made before then still count.
    private var isStoppingPipeline = false
    private var recorder: SessionRecorder?
    private var shotCounter = 0
    /// The tracker's latest call and when it landed (see `correctableShot`).
    private var lastAutoCall: (shot: ShotRecord, at: Date)?
    /// Now; tests move it on to step past the correction window.
    var clock: () -> Date = { .now }
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

    #if DEBUG
    /// Tests: run the session on `pipeline` (start() only builds one when
    /// the camera is available).
    func useForTesting(pipeline: any ShotPipelineControl) {
        self.pipeline = pipeline
    }
    #endif

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
        camera.stopSession()
        let recorder = self.recorder
        self.recorder = nil
        Task {
            // As in end(): calls made before the view went away count.
            await stopPipeline()
            guard let session else { return }
            if attempts == 0 {
                dataService.discardSession(session)
                if let url = await recorder?.finish() { try? FileManager.default.removeItem(at: url) }
            } else {
                session.videoFileName = await recorder?.finish()?.lastPathComponent
                _ = try? await coordinator.finaliseSession(session, activeDuration: active)
                if let playoffSeries { dataService.refreshPlayoff(playoffSeries) }
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

    /// Finishes the session. Nil when an end is already under way.
    func end() async -> SessionEnd? {
        guard phase != .ending else { return nil }
        phase = .ending
        let active = activeElapsed()
        limitWatcher?.cancel()
        flightTimeout?.cancel()
        // Before anything is decided: a shot called just before End counts.
        await stopPipeline()
        let videoURL = await finishRecording()
        camera.stopSession()

        // The session never started (the error was shown): just leave.
        guard let session else { return .discarded }

        // No shots: an empty session would still count as a training day
        // and a session. tearDown() already dropped these; now ending does too.
        if attempts == 0 {
            if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
            dataService.discardSession(session)
            return .discarded
        }

        // A retry after a failed save has no recorder left; keep the name
        // the first attempt stored.
        if let videoURL { session.videoFileName = videoURL.lastPathComponent }
        do {
            let result = try await coordinator.finaliseSession(session, activeDuration: active)
            if let playoffSeries { dataService.refreshPlayoff(playoffSeries) }
            haptics.milestone()
            return .saved(result)
        } catch {
            errorMessage = error.localizedDescription
            phase = .live
            return .failed
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

    /// The Make / Miss buttons. Right after an automatic call, the other
    /// result means "that call was wrong": it changes the call instead of
    /// logging a second shot (tapping Make on a wrong miss used to count
    /// both). Otherwise, or with the same result, it logs a shot.
    func logManual(_ result: ShotResult) {
        guard phase == .live else { return }
        if let shot = correctableShot, shot.result != result {
            correct(shot, to: result)
            return
        }
        record(result: result, zone: .unknown, courtX: 0.5, courtY: 0.5,
               science: nil, videoOffset: nil, detectionConfidence: nil)
    }

    /// The automatic call a tap of the other result would change: the
    /// latest shot, called by the tracker, within the correction window,
    /// with no shot started since and not already changed.
    var correctableShot: ShotRecord? {
        guard let call = lastAutoCall,
              clock().timeIntervalSince(call.at) <= HoopTrack.CV.correctionWindowSec,
              session?.orderedShots.last?.id == call.shot.id else { return nil }
        return call.shot
    }

    private func correct(_ shot: ShotRecord, to result: ShotResult) {
        lastAutoCall = nil
        dataService.updateShot(shot, result: result)
        refreshCounts()
        shotCounter += 1
        lastShot = ShotFlash(result: result, id: shotCounter, corrected: true)
        result == .make ? haptics.makeMade() : haptics.missMade()
        if UIAccessibility.isVoiceOverRunning {
            let word = result == .make ? "make" : "miss"
            UIAccessibility.post(notification: .announcement, argument: "Changed to \(word). \(makes) for \(attempts).")
        }
        updatePlayoff(announce: true, replacingMoment: true)
    }

    /// Removes the most recent shot (wrong call, or a shot that never happened).
    func undoLast() {
        lastAutoCall = nil
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
        // A tap from now on is about this shot, not the last call.
        lastAutoCall = nil
        shotInFlight = true
        flightTimeout?.cancel()
        flightTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.shotInFlight = false
        }
    }

    func pipelineShotResolved(_ shot: DetectedShot) {
        shotInFlight = false
        // Paused or not: the pipeline calls nothing while paused, but on the
        // first paused frame it settles a call still waiting for the net
        // ("a call already made stands") and that lands here after the pause.
        guard phase == .live || isStoppingPipeline else { return }
        record(result: shot.result, zone: shot.zone, courtX: shot.courtX, courtY: shot.courtY,
               science: shot.science, videoOffset: shot.videoOffset,
               detectionConfidence: shot.confidence)
    }

    // MARK: - Private

    /// Stops the pipeline (on its own queue, after the frame in progress)
    /// and records what it called before the session ended: deliveries that
    /// arrive meanwhile, then what stop() hands back — a call still waiting
    /// on the net check, or one whose delivery hadn't run yet.
    private func stopPipeline() async {
        guard let pipeline else { return }
        self.pipeline = nil
        isStoppingPipeline = true
        let last = await pipeline.stop()
        last.forEach(pipelineShotResolved)
        isStoppingPipeline = false
    }

    private func record(result: ShotResult, zone: CourtZone, courtX: Double, courtY: Double,
                        science: ShotScienceMetrics?, videoOffset: Double?,
                        detectionConfidence: Double?) {
        guard let session, phase == .live || isStoppingPipeline else { return }
        // Counted quietly once the session is ending: the screen is going.
        let ending = phase != .live
        do {
            let shot = try dataService.addShot(to: session, result: result, zone: zone, shotType: .unknown,
                                               courtX: courtX, courtY: courtY, science: science,
                                               videoOffset: videoOffset ?? recordingOffsetNow(),
                                               needsReview: (detectionConfidence ?? 1) < HoopTrack.CV.lowConfidence,
                                               detectionConfidence: detectionConfidence)
            // Only the tracker's calls can be changed by a tap; a shot
            // logged by hand closes the window.
            lastAutoCall = detectionConfidence != nil && !ending ? (shot, clock()) : nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        refreshCounts()
        guard !ending else {
            updatePlayoff(announce: false)
            return
        }
        shotCounter += 1
        lastShot = ShotFlash(result: result, id: shotCounter)
        result == .make ? haptics.makeMade() : haptics.missMade()
        announce(result)
        updatePlayoff(announce: true)
    }

    /// Replays this sitting's shots on top of the run as it stood, so an
    /// undo un-decides a game as cleanly as a shot decides one.
    /// `replacingMoment`: the last shot's result changed, so a moment it
    /// showed (a game won, a series won) goes if the new result decides
    /// nothing.
    private func updatePlayoff(announce: Bool, replacingMoment: Bool = false) {
        guard let base = playoffBase, let session else { return }
        var run = base
        var event: PlayoffEvent?
        for shot in session.orderedShots { event = run.record(shot.result) }
        playoff = run
        guard announce, let event else {
            if !announce || replacingMoment { playoffMoment = nil }
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
    /// A tap changed the tracker's call to this.
    var corrected = false
}
