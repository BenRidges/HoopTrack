// HoopTrack/Services/CVPipeline.swift
// Per-frame shot detection on the camera's session queue:
//
//   frame ─▶ SessionRecorder (video)
//         ─▶ detector (ball candidates + hoop; cropped around the hoop
//            while a shot is in flight — see DetectionRegion)
//         ─▶ CourtCalibrationService (smoothed rim)
//         ─▶ ShotTracker (make / miss state machine)
//         ─▶ NetWatch / NetCheck (unsure calls wait for the net to swing)
//         ─▶ CourtPositionEstimator + ShotPhysics (where from, what arc)
//         ─▶ delegate on the main actor
//
// All mutable state is touched only on the pipeline's own serial queue:
// each frame is processed there, synchronously, from the Combine sink (so
// the camera's session queue still waits for it and late frames are still
// discarded there), and stop() runs there too, after any frame in progress.
// The `nonisolated(unsafe)` annotations record that the compiler can't
// prove it.

import AVFoundation
import Combine
import CoreGraphics
import Foundation

// MARK: - Output types

/// A shot the pipeline has called, ready to be logged.
nonisolated struct DetectedShot: Sendable {
    let result: ShotResult
    let confidence: Double
    let courtX: Double
    let courtY: Double
    let zone: CourtZone
    let distanceFt: Double?
    let science: ShotScienceMetrics?
    /// Seconds into the session video where the shot was released.
    let videoOffset: Double?
}

@MainActor protocol ShotPipelineDelegate: AnyObject, Sendable {
    func pipelineHoopChanged(_ state: CalibrationState)
    func pipelineBallMoved(_ box: CGRect?)
    func pipelineShotStarted()
    func pipelineShotResolved(_ shot: DetectedShot)
}

/// What a session does with its pipeline once it's running (CVPipeline;
/// a stand-in in tests).
nonisolated protocol ShotPipelineControl: AnyObject, Sendable {
    /// Shots aren't detected while paused.
    var isPaused: Bool { get set }
    /// Stops it for good. Returns the calls it made that the delegate
    /// hasn't been handed, oldest first; each call arrives exactly once,
    /// through the delegate or here.
    func stop() async -> [DetectedShot]
}

// MARK: - CVPipeline

nonisolated final class CVPipeline: ShotPipelineControl, @unchecked Sendable {

    /// Nil in manual mode (no model bundled): the pipeline then only records.
    private let detector: BallDetectorProtocol?
    private let calibration = CourtCalibrationService()
    private let threePointDistanceFt: Double
    private let fieldOfView: @Sendable () -> Double

    /// Frames are processed here one at a time, and stop() runs here: see
    /// the top of the file.
    private let queue = DispatchQueue(label: "com.hooptrack.cv.pipeline", qos: .userInitiated)
    /// Set by stop(); frames after it are ignored.
    nonisolated(unsafe) private var isStopped = false
    /// Calls on their way to the delegate.
    private let outbox = ShotOutbox()

    nonisolated(unsafe) private var tracker = ShotTracker()
    nonisolated(unsafe) private var frameCancellable: AnyCancellable?
    nonisolated(unsafe) private weak var delegate: ShotPipelineDelegate?

    /// Video is written for the whole session, paused or not, except in a
    /// long break (the recorder's `isHolding`): see SessionRecorder. A shot
    /// starting ends the break here, on the frame it's seen, rather than
    /// when the main actor hears of it.
    nonisolated(unsafe) var recorder: SessionRecorder?
    /// Shots aren't detected while paused. Set from the main actor at any
    /// time and read on the pipeline queue every frame, hence the lock.
    var isPaused: Bool {
        get { pauseLock.withLock { paused } }
        set { pauseLock.withLock { paused = newValue } }
    }
    private let pauseLock = NSLock()
    nonisolated(unsafe) private var paused = false
    /// Publishes the ball box for the debug overlay (set before start()).
    nonisolated(unsafe) var publishesBall = false

    // CV-A telemetry
    nonisolated(unsafe) private var detectionLogger: DetectionLogger?
    nonisolated(unsafe) private var sessionStartTime: Double?

    // Main-actor update throttling
    nonisolated(unsafe) private var lastHoopKind = -1
    nonisolated(unsafe) private var lastHoopPublish: Double = 0
    nonisolated(unsafe) private var lastBallPublish: Double = 0

    // Shot in flight
    nonisolated(unsafe) private var pendingEstimate: CourtPositionEstimator.Estimate?

    // CV-D — net movement as a second opinion on unsure calls
    nonisolated(unsafe) private var net = NetWatch()
    nonisolated(unsafe) private var netCheck = NetCheck<CourtPositionEstimator.Estimate?>()

    // Load shedding
    nonisolated(unsafe) private var frameIndex = 0
    nonisolated(unsafe) private var wasPaused = false
    nonisolated(unsafe) private var isHot = false

    init(detector: BallDetectorProtocol?,
         threePointDistanceFt: Double,
         fieldOfView: @escaping @Sendable () -> Double) {
        self.detector = detector
        self.threePointDistanceFt = threePointDistanceFt
        self.fieldOfView = fieldOfView
    }

    // MARK: - Lifecycle

    func start(framePublisher: AnyPublisher<CMSampleBuffer, Never>, delegate: ShotPipelineDelegate) {
        self.delegate = delegate
        let queue = self.queue
        frameCancellable = framePublisher.sink { [weak self] buffer in
            // Synchronous: the camera's queue waits, as if processed there.
            queue.sync { self?.process(buffer) }
        }
    }

    /// Ends the session's analysis. Runs on the pipeline's queue, after any
    /// frame in progress, so it never races one (it used to run on the main
    /// actor while the session queue could be mid-frame: tracker, net check
    /// and log writer touched from two threads at once). Frames after it are
    /// ignored.
    ///
    /// A call still waiting for the net check is settled with the footage
    /// there is and returned — the shot happened, the session just ended
    /// before the net had its full 0.7 s (ShotReplay does the same at the end
    /// of a log). So is any call published whose main-actor delivery hasn't
    /// run yet. Call from the main actor (start/stop own the subscription).
    func stop() async -> [DetectedShot] {
        frameCancellable?.cancel()
        frameCancellable = nil
        return await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: finish()) }
        }
    }

    /// stop()'s work, on the pipeline queue.
    private func finish() -> [DetectedShot] {
        guard !isStopped else { return outbox.takeAll() }
        isStopped = true
        var last = outbox.takeAll()
        if let call = netCheck.flush(meter: net.meter) {
            last.append(makeShot(from: call.outcome, estimate: call.context,
                                 result: call.result, confidence: call.confidence))
        }
        tracker.reset()
        calibration.reset()
        net.reset()
        netCheck.drop()
        pendingEstimate = nil
        detectionLogger?.close()
        detectionLogger = nil
        return last
    }

    func attachTelemetry(logger: DetectionLogger) {
        detectionLogger = logger
        sessionStartTime = nil
    }

    // MARK: - Frame processing

    private func process(_ buffer: CMSampleBuffer) {
        // A frame the camera delivered just before stop() cancelled the feed.
        guard !isStopped else { return }
        recorder?.append(buffer)
        // A shot in the air when the session is paused would otherwise
        // resolve on resume as a lost-ball guess: drop it.
        if isPaused {
            if !wasPaused {
                tracker.reset()
                pendingEstimate = nil
                // A call already made stands; it just can't wait for the net.
                if let call = netCheck.flush(meter: net.meter) { publish(call) }
                net.reset()
            }
            wasPaused = true
            return
        }
        wasPaused = false
        guard let detector else { return }

        // Check the temperature about once a second; when hot, detect on
        // alternate frames. The tracker works from timestamps, so it copes.
        frameIndex &+= 1
        if frameIndex % 60 == 0 {
            isHot = ProcessInfo.processInfo.thermalState.rawValue >= HoopTrack.CV.throttleAtThermalState
        }
        if isHot && frameIndex % 2 == 1 { return }

        let region = focusRegion(for: buffer)
        guard let scene = detector.detectScene(buffer: buffer, region: region) else { return }
        let now = CMTimeGetSeconds(scene.frameTimestamp)

        calibration.updateBaskets(scene.baskets, timestamp: scene.frameTimestamp)
        publishHoop(now: now)
        publishBall(scene.ball?.boundingBox, now: now)

        // Before the tracker: on the frame a shot resolves the grid should
        // still be on the rim the shot was judged against.
        let netActivity = watchNet(buffer, now: now)

        let event = tracker.update(balls: scene.balls.map(\.boundingBox),
                                   hoop: calibration.state.hoopRect,
                                   time: now)
        var published: [NetCheck<CourtPositionEstimator.Estimate?>.Call] = []
        switch event {
        case .started(let release):
            recorder?.isHolding = false
            // A held call can't wait through another shot.
            if let call = netCheck.flush(meter: net.meter) { published.append(call) }
            pendingEstimate = calibration.state.hoopRect.flatMap { hoop in
                CourtPositionEstimator.estimate(ballBox: release.box,
                                                ballDiameter: release.ballDiameter,
                                                rimBox: hoop,
                                                horizontalFOV: fieldOfView())
            }

        case .resolved(let outcome):
            published += netCheck.submit(outcome, context: pendingEstimate, now: now, meter: net.meter)
            pendingEstimate = nil

        case nil:
            if let call = netCheck.due(now: now, meter: net.meter) { published.append(call) }
        }
        logTelemetry(scene, region: region, event: event, netActivity: netActivity,
                     published: published.last, now: now)

        published.forEach(publish)
        if case .started = event {
            Task { @MainActor [weak delegate] in delegate?.pipelineShotStarted() }
        }
    }

    private func publish(_ call: NetCheck<CourtPositionEstimator.Estimate?>.Call) {
        let shot = makeShot(from: call.outcome, estimate: call.context,
                            result: call.result, confidence: call.confidence)
        let outbox = self.outbox
        let id = outbox.put(shot)
        Task { @MainActor [weak delegate] in
            // Nil when stop() got there first and handed it over itself.
            guard let shot = outbox.take(id) else { return }
            delegate?.pipelineShotResolved(shot)
        }
    }

    // MARK: - Net (CV-D)

    /// Samples the net's brightness and records how much it changed.
    private func watchNet(_ buffer: CMSampleBuffer, now: Double) -> Double? {
        let hoop = tracker.lockedHoop ?? netCheck.heldHoop ?? calibration.state.hoopRect
        let points = net.aim(at: hoop, aspect: tracker.aspect)
        return net.observe(points.isEmpty ? nil : Self.luma(at: points, in: buffer), at: now)
    }

    /// Brightness at each point (Vision-normalised) from the frame's luma
    /// plane, each the mean of a 2×2 patch two pixels apart, which steadies
    /// sensor noise.
    private static func luma(at points: [CGPoint], in buffer: CMSampleBuffer) -> [UInt8]? {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer),
              CVPixelBufferIsPlanar(pixels),
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        guard width > 2, height > 2 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        return points.map { point in
            // Vision's origin is bottom-left; pixel rows start at the top.
            let x = min(width - 3, max(0, Int(Double(point.x) * Double(width))))
            let y = min(height - 3, max(0, Int((1 - Double(point.y)) * Double(height))))
            let top = y * rowBytes + x, bottom = (y + 2) * rowBytes + x
            let sum = Int(bytes[top]) + Int(bytes[top + 2]) + Int(bytes[bottom]) + Int(bytes[bottom + 2])
            return UInt8(sum / 4)
        }
    }

    /// A crop around the hoop and the shot ball while a shot is in flight;
    /// nil (full frame) otherwise, so a new release anywhere is still seen.
    private func focusRegion(for buffer: CMSampleBuffer) -> CGRect? {
        guard HoopTrack.CV.focusDuringShots,
              let ball = tracker.shotBallBox,
              let hoop = calibration.state.hoopRect,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        return DetectionRegion.around(hoop: hoop, ball: ball,
                                      frameWidth: Double(CVPixelBufferGetWidth(pixels)),
                                      frameHeight: Double(CVPixelBufferGetHeight(pixels)))
    }

    private func makeShot(from outcome: ShotTracker.Outcome,
                          estimate: CourtPositionEstimator.Estimate?,
                          result: ShotResult, confidence: Double) -> DetectedShot {
        let position = estimate.map(CourtPositionEstimator.courtPosition(for:))
        let zone = position.map {
            CourtZoneClassifier.classify(courtX: $0.courtX, courtY: $0.courtY,
                                         threePointDistanceFt: threePointDistanceFt)
        } ?? .unknown

        var science: ShotScienceMetrics?
        if let estimate, let arrival = outcome.rimArrivalTime,
           let launch = ShotPhysics.launch(horizontalDistanceM: estimate.distanceM,
                                           flightTime: arrival - outcome.release.time) {
            science = ShotScienceMetrics(releaseAngleDeg: launch.angleDeg, shotSpeedMph: launch.speedMph)
        }

        return DetectedShot(result: result,
                            confidence: confidence,
                            courtX: position?.courtX ?? 0.5,
                            courtY: position?.courtY ?? 0.5,
                            zone: zone,
                            distanceFt: estimate?.distanceFt,
                            science: science,
                            videoOffset: recorder?.fileOffset(of: outcome.release.time))
    }

    // MARK: - Main-actor publishing (throttled)

    private func publishHoop(now: Double) {
        let state = calibration.state
        let kind: Int
        switch state {
        case .looking:  kind = 0
        case .tracking: kind = 1
        case .lost:     kind = 2
        }
        // State changes go out immediately; rect movement at ~15 Hz.
        guard kind != lastHoopKind || (kind == 1 && now - lastHoopPublish > 1.0 / 15) else { return }
        lastHoopKind = kind
        lastHoopPublish = now
        Task { @MainActor [weak delegate] in delegate?.pipelineHoopChanged(state) }
    }

    private func publishBall(_ box: CGRect?, now: Double) {
        guard publishesBall, now - lastBallPublish > 1.0 / 20 else { return }
        lastBallPublish = now
        Task { @MainActor [weak delegate] in delegate?.pipelineBallMoved(box) }
    }

    // MARK: - Telemetry (CV-A)

    /// Everything needed to replay the frame offline (Tools/HoopTrackCore
    /// shot-eval): all ball candidates, every hoop candidate (the smoother
    /// chose from all of them), the crop, net movement, the tracker's call
    /// and the call published after the net check.
    private func logTelemetry(_ scene: SceneDetection, region: CGRect?,
                              event: ShotTracker.Event?, netActivity: Double?,
                              published: NetCheck<CourtPositionEstimator.Estimate?>.Call?,
                              now: Double) {
        guard let logger = detectionLogger else { return }
        // Log times are measured from the video's first frame, so they line
        // up with the session video (and its extracted telemetry frames).
        if sessionStartTime == nil { sessionStartTime = recorder?.startTime ?? now }
        func box(_ r: CGRect) -> [Double] {
            [Double(r.origin.x), Double(r.origin.y), Double(r.width), Double(r.height)]
        }
        var entry = DetectionLogEntry(
            timestampSec:   now - (sessionStartTime ?? now),
            ballConfidence: scene.ball.map { Double($0.confidence) },
            ballBox:        scene.ball.map { box($0.boundingBox) },
            rimConfidence:  scene.basket.map { Double($0.confidence) },
            rimBox:         scene.basket.map { box($0.boundingBox) },
            state:          tracker.isTrackingShot ? "tracking" : "idle"
        )
        entry.balls = scene.balls.map { box($0.boundingBox) + [Double($0.confidence)] }
        entry.baskets = scene.baskets.map { box($0.boundingBox) + [Double($0.confidence)] }
        entry.region = region.map(box)
        switch event {
        case .started:
            entry.event = "start"
        case .resolved(let outcome):
            entry.event = outcome.result == .make ? "make" : "miss"
            entry.eventConfidence = outcome.confidence
        case nil:
            break
        }
        entry.netActivity = netActivity
        if let published {
            entry.checkedEvent = published.result == .make ? "make" : "miss"
            entry.checkedConfidence = published.confidence
        }
        logger.log(entry)
    }
}

// MARK: - Outbox

/// Calls on their way from the pipeline queue to the main actor. Each is
/// handed over exactly once: by the Task published with it, or by stop() if
/// that runs first — so a call published just before the session ends is
/// neither lost nor counted twice.
nonisolated private final class ShotOutbox: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    private var waiting: [(id: Int, shot: DetectedShot)] = []

    func put(_ shot: DetectedShot) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        waiting.append((nextID, shot))
        return nextID
    }

    func take(_ id: Int) -> DetectedShot? {
        lock.lock(); defer { lock.unlock() }
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
        return waiting.remove(at: index).shot
    }

    /// Everything not yet handed over, oldest first.
    func takeAll() -> [DetectedShot] {
        lock.lock(); defer { lock.unlock() }
        let all = waiting.map(\.shot)
        waiting.removeAll()
        return all
    }
}
