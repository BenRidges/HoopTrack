// LiveSessionViewModel.swift
// Owns one live shooting session: camera, CV pipeline, recording, timer,
// shot log and the hand-off to SessionFinalizationCoordinator.
//
// The session options (Profile → Session options) live here too: calls
// said out loud (SessionAnnouncing), setup tips from the rim's place in the
// picture, named-drill steps, a timed drill's clock waiting for the first
// shot, pausing when nobody's shooting, and a target to chase.
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
    /// A timed drill whose clock starts on the first shot, still waiting.
    @Published private(set) var isClockWaiting = false

    // Session options
    /// The setup tip on screen; nil once shooting starts (or tips are off).
    @Published private(set) var setupAdvice: SetupAdvice?
    /// Where a named drill is up to; nil without drill guidance.
    @Published private(set) var drillProgress: DrillProgress?
    /// "Move to the right wing": changes when a drill step is done.
    @Published private(set) var drillCue: DrillCue?
    /// Nobody's shot for a while: the clock (and video) are paused until
    /// the next shot. Not the same as `isPaused`, which the player chose.
    @Published private(set) var isIdle = false
    /// Paused so long the session may be over: ask.
    @Published private(set) var idlePrompt = false
    /// Nobody answered: the view ends (and saves) the session.
    @Published private(set) var idleTimedOut = false
    /// Your best (or goal) for the live screen.
    @Published private(set) var target: SessionTarget?
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
    let options: SessionOptions
    private let announcer: (any SessionAnnouncing)?
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
    private var idleWatcher: Task<Void, Never>?
    /// The last shot, tap or button press (see `checkIdle`).
    private var lastActivity = Date.distantPast
    /// Video in a long break can be cut (not with telemetry on: its frames
    /// are found in the video by log time).
    private var canCutVideo = true
    private var drillPlan: DrillPlan?
    private var cueCounter = 0
    private var targetMet = false
    // Setup tips: the tip waiting to settle, and whether to stop giving them.
    private var adviceCandidate: (advice: SetupAdvice, since: Date)?
    private var setupDone = false
    private var hoopFoundOnce = false
    private var lastTipSpoken = Date.distantPast
    private var courtType: CourtType = .nba
    private var showDetectionBoxes = false

    // Active-time clock (pauses, breaks and a timed drill's wait excluded).
    private var runningSince: Date?
    private var accumulated: TimeInterval = 0

    init(namedDrill: NamedDrill?,
         playoffSeriesID: UUID? = nil,
         dataService: DataService,
         coordinator: SessionFinalizationCoordinator,
         camera: CameraService,
         haptics: HapticService,
         options: SessionOptions = .none,
         announcer: (any SessionAnnouncing)? = nil) {
        self.namedDrill = namedDrill
        self.playoffSeriesID = playoffSeriesID
        self.dataService = dataService
        self.coordinator = coordinator
        self.camera = camera
        self.haptics = haptics
        self.options = options
        self.announcer = announcer
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
        announcer?.begin(mode: options.shotCalls)
        if options.drillGuidance, series == nil {
            drillPlan = namedDrill.flatMap(DrillPlan.plan(for:))
            drillProgress = drillPlan?.progress(after: 0)
        }
        if options.showTarget, series == nil, let profile {
            target = Self.target(for: namedDrill, profile: profile, excluding: session?.id)
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
    /// the camera is available), tracking as if a detector were there.
    func useForTesting(pipeline: any ShotPipelineControl) {
        self.pipeline = pipeline
        if hoopStatus == .manual { hoopStatus = .searching }
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
            canCutVideo = false
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
        stopWatchers()
        announcer?.end()
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
            // A pause the player chose replaces a break the app noticed.
            leaveIdle()
            stopClock()
            shotInFlight = false
        } else {
            lastActivity = clock()
            runClockIfDue()
        }
        haptics.tap()
    }

    /// Finishes the session. Nil when an end is already under way.
    func end() async -> SessionEnd? {
        guard phase != .ending else { return nil }
        phase = .ending
        let active = activeElapsed()
        stopWatchers()
        announcer?.end()
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

    func activeElapsed(at date: Date? = nil) -> TimeInterval {
        let now = date ?? clock()
        return accumulated + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    private func beginClock() {
        // A timed drill can wait for the first shot: the walk from the
        // phone to the court isn't part of your five minutes.
        isClockWaiting = timeLimit != nil && options.timedDrillsWaitForShot
        lastActivity = clock()
        phase = .live
        runClockIfDue()
        if options.autoPause {
            idleWatcher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    self?.checkIdle()
                }
            }
        }
        guard let limit = timeLimit else { return }
        limitWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if self.activeElapsed() >= limit {
                    self.haptics.longPress()
                    self.announcer?.say("Time. \(self.makes.counted("make")).")
                    self.timeIsUp = true
                    return
                }
            }
        }
    }

    /// The clock runs unless paused, in a break, or waiting for a timed
    /// drill's first shot.
    private func runClockIfDue() {
        guard runningSince == nil, !isPaused, !isIdle, !isClockWaiting, phase == .live else { return }
        runningSince = clock()
    }

    /// `at`: when the time stopped counting, if before now.
    private func stopClock(at end: Date? = nil) {
        if let since = runningSince { accumulated += max(0, (end ?? clock()).timeIntervalSince(since)) }
        runningSince = nil
    }

    private func stopWatchers() {
        limitWatcher?.cancel()
        idleWatcher?.cancel()
        flightTimeout?.cancel()
    }

    /// A shot (or the player): the clock starts, a break ends.
    private func noteShotActivity() {
        lastActivity = clock()
        if isClockWaiting {
            isClockWaiting = false
            runClockIfDue()
        }
        leaveIdle()
        if !setupDone {
            setupDone = true
            setupAdvice = nil
        }
    }

    // MARK: - Breaks (auto-pause)

    /// The screen was touched: somebody's there.
    func noteActivity() {
        guard phase == .live else { return }
        lastActivity = clock()
        leaveIdle()
    }

    /// Called every few seconds. No shot (or touch) for two minutes and the
    /// clock and the video pause until the next one; after fifteen it asks
    /// whether you're done, and after twenty it ends and saves the session,
    /// so a phone left running at the court doesn't record all evening.
    func checkIdle() {
        guard options.autoPause, phase == .live, !isPaused else { return }
        let quiet = clock().timeIntervalSince(lastActivity)
        if !isIdle, quiet >= HoopTrack.Session.idlePauseSec {
            isIdle = true
            // The two quiet minutes weren't training either.
            stopClock(at: lastActivity)
            if canCutVideo { recorder?.isHolding = true }
            announcer?.say("Paused. Shoot to carry on.")
        }
        guard isIdle else { return }
        if !idlePrompt, quiet >= HoopTrack.Session.idleAskSec {
            idlePrompt = true
            announcer?.say("Still shooting? The session ends in five minutes.")
        }
        if !idleTimedOut, quiet >= HoopTrack.Session.idleEndSec {
            idleTimedOut = true
        }
    }

    private func leaveIdle() {
        guard isIdle else { return }
        isIdle = false
        idlePrompt = false
        recorder?.isHolding = false
        runClockIfDue()
    }

    // MARK: - Manual logging & corrections

    /// The Make / Miss buttons. Right after an automatic call, the other
    /// result means "that call was wrong": it changes the call instead of
    /// logging a second shot (tapping Make on a wrong miss used to count
    /// both). Otherwise, or with the same result, it logs a shot.
    func logManual(_ result: ShotResult) {
        guard phase == .live else { return }
        lastActivity = clock()
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
        announcer?.shot(result, makes: makes, attempts: attempts, corrected: true)
        updatePlayoff(announce: true, replacingMoment: true)
        updateTarget(announce: true)
    }

    /// Removes the most recent shot (wrong call, or a shot that never happened).
    func undoLast() {
        lastAutoCall = nil
        noteActivity()
        guard let session, let last = session.orderedShots.last else { return }
        dataService.deleteShot(last)
        refreshCounts()
        updatePlayoff(announce: false)
        updateDrill(announce: false)
        updateTarget(announce: false)
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
            lastActivity = clock()
        }
        updateSetupAdvice(state)
    }

    /// Hoop found: with tips on, the first settled tip is said with it
    /// ("Hoop found. Too close…"); without, it's said straight away.
    private func announceHoopFound(_ advice: SetupAdvice?) {
        guard !hoopFoundOnce else { return }
        hoopFoundOnce = true
        var words = "Hoop found. " + (advice?.spoken ?? "Start shooting.")
        if isClockWaiting { words += " The clock starts on your first shot." }
        announcer?.say(words)
    }

    /// Setup tips until the first shot: a tip shows once it has held for
    /// `setupSettleSec`, and is said when it changes.
    private func updateSetupAdvice(_ state: CalibrationState) {
        guard options.setupCoach, !setupDone else {
            if state.isTracking { announceHoopFound(nil) }
            return
        }
        guard case .tracking(let rect) = state else {
            adviceCandidate = nil
            if case .looking = state { setupAdvice = nil }
            return
        }
        let advice = SetupCheck.advice(hoop: rect)
        let now = clock()
        if adviceCandidate?.advice != advice { adviceCandidate = (advice, now) }
        guard let candidate = adviceCandidate, advice != setupAdvice,
              now.timeIntervalSince(candidate.since) >= HoopTrack.Session.setupSettleSec else { return }
        setupAdvice = advice
        if !hoopFoundOnce {
            announceHoopFound(advice)
            lastTipSpoken = now
        } else if now.timeIntervalSince(lastTipSpoken) >= Self.tipSpacingSec {
            // A rim on the edge of a limit can flip between two tips; the
            // screen keeps up, the voice doesn't nag.
            announcer?.say(advice.spoken)
            lastTipSpoken = now
        }
    }

    private static let tipSpacingSec: Double = 4

    func pipelineBallMoved(_ box: CGRect?) {
        ballBox = box
    }

    func pipelineShotStarted() {
        guard !isPaused else { return }
        noteShotActivity()
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
        if !ending { noteShotActivity() }
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
            updateDrill(announce: false)
            return
        }
        shotCounter += 1
        lastShot = ShotFlash(result: result, id: shotCounter)
        result == .make ? haptics.makeMade() : haptics.missMade()
        announcer?.shot(result, makes: makes, attempts: attempts, corrected: false)
        updatePlayoff(announce: true)
        updateDrill(announce: true)
        updateTarget(announce: true)
    }

    /// Moves the drill on after a shot; at the end of a step, says how it
    /// went and where to go next.
    private func updateDrill(announce: Bool) {
        guard let plan = drillPlan else { return }
        let before = drillProgress
        let now = plan.progress(after: attempts)
        drillProgress = now
        guard announce, let before, !now.isSameStep(as: before), attempts > 0 else { return }
        // How the step just finished went: its last `shotsInStep` shots.
        let stepShots = session?.orderedShots.suffix(before.shotsInStep) ?? []
        let made = stepShots.filter(\.isMake).count
        let score = "\(made) of \(stepShots.count)"
        let text: String
        let spoken: String
        if now.isFinished {
            text = "Drill done · \(makes) of \(attempts)"
            spoken = "Drill done. \(makes) of \(attempts). Hold End to finish."
        } else if now.stepCount == nil {
            text = "\(now.stepLabel)"
            spoken = "\(before.stepName) done, \(score). \(now.stepLabel)."
        } else {
            text = "Move to the \(now.spot.lowercased())"
            spoken = "\(score). Move to the \(now.spot.lowercased())."
        }
        cueCounter += 1
        drillCue = DrillCue(text: text, id: cueCounter, isFinished: now.isFinished)
        announcer?.say(spoken)
        if now.isFinished { haptics.milestone() }
    }

    /// Says so once when a best is beaten.
    private func updateTarget(announce: Bool) {
        guard let target else { return }
        let met = target.isMet(makes: makes, attempts: attempts)
        defer { targetMet = met }
        guard announce, met, !targetMet, case .makes = target else { return }
        haptics.milestone()
        announcer?.say("New best!")
    }

    /// Your best makes in this drill, or for a free session your field-goal
    /// goal, else your most makes in any session.
    private static func target(for drill: NamedDrill?, profile: PlayerProfile,
                               excluding current: UUID?) -> SessionTarget? {
        let drillBest = drill.flatMap { drill in
            profile.sessions
                .filter { $0.namedDrill == drill && $0.isComplete && $0.id != current }
                .map(\.shotsMade).max()
        }
        let fgGoal = profile.goals
            .filter { $0.metric == .fgPercent && !$0.isAchieved }
            .map(\.targetValue).min()
        return SessionTarget.choose(drillBest: drillBest, isNamedDrill: drill != nil,
                                    fgGoal: fgGoal, mostMakes: profile.prMostMakesSession)
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
        announcer?.say(PlayoffMoment.spoken(event, run: run))
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
        recorder?.fileOffset(of: CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())))
    }

    private func finishRecording() async -> URL? {
        let recorder = self.recorder
        self.recorder = nil
        return await recorder?.finish()
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

/// A drill step just finished, for the live screen's cue.
struct DrillCue: Equatable {
    let text: String
    let id: Int
    var isFinished = false
}

struct ShotFlash: Equatable {
    let result: ShotResult
    let id: Int
    /// A tap changed the tracker's call to this.
    var corrected = false
}
