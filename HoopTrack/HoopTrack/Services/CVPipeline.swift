// HoopTrack/Services/CVPipeline.swift
// Per-frame shot detection on the camera's session queue:
//
//   frame ─▶ SessionRecorder (video)
//         ─▶ detector (ball candidates + hoop; cropped around the hoop
//            while a shot is in flight — see DetectionRegion)
//         ─▶ CourtCalibrationService (smoothed rim)
//         ─▶ ShotTracker (make / miss state machine)
//         ─▶ CourtPositionEstimator + ShotPhysics (where from, what arc)
//         ─▶ delegate on the main actor
//
// All mutable state is touched only from the Combine sink, which runs
// synchronously on the serial session queue that delivers frames. The
// `nonisolated(unsafe)` annotations record that the compiler can't prove it.

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

// MARK: - CVPipeline

nonisolated final class CVPipeline: @unchecked Sendable {

    /// Nil in manual mode (no model bundled): the pipeline then only records.
    private let detector: BallDetectorProtocol?
    private let calibration = CourtCalibrationService()
    private let threePointDistanceFt: Double
    private let fieldOfView: @Sendable () -> Double

    nonisolated(unsafe) private var tracker = ShotTracker()
    nonisolated(unsafe) private var frameCancellable: AnyCancellable?
    nonisolated(unsafe) private weak var delegate: ShotPipelineDelegate?

    /// Video is written for the whole session, paused or not, so shot
    /// offsets line up with the file.
    nonisolated(unsafe) var recorder: SessionRecorder?
    /// Shots aren't detected while paused.
    nonisolated(unsafe) var isPaused = false
    /// Publishes the ball box for the debug overlay.
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

    // Load shedding
    nonisolated(unsafe) private var frameIndex = 0
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
        frameCancellable = framePublisher.sink { [weak self] buffer in
            self?.process(buffer)
        }
    }

    func stop() {
        frameCancellable?.cancel()
        frameCancellable = nil
        tracker.reset()
        calibration.reset()
        detectionLogger?.close()
        detectionLogger = nil
    }

    func attachTelemetry(logger: DetectionLogger) {
        detectionLogger = logger
        sessionStartTime = nil
    }

    // MARK: - Frame processing

    private func process(_ buffer: CMSampleBuffer) {
        recorder?.append(buffer)
        guard !isPaused, let detector else { return }

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

        calibration.updateBasket(scene.basket, timestamp: scene.frameTimestamp)
        publishHoop(now: now)
        publishBall(scene.ball?.boundingBox, now: now)

        let event = tracker.update(balls: scene.balls.map(\.boundingBox),
                                   hoop: calibration.state.hoopRect,
                                   time: now)
        logTelemetry(scene, region: region, event: event, now: now)
        switch event {
        case .started(let release):
            pendingEstimate = calibration.state.hoopRect.flatMap { hoop in
                CourtPositionEstimator.estimate(ballBox: release.box,
                                                ballDiameter: release.ballDiameter,
                                                rimBox: hoop,
                                                horizontalFOV: fieldOfView())
            }
            Task { @MainActor [weak delegate] in delegate?.pipelineShotStarted() }

        case .resolved(let outcome):
            let shot = makeShot(from: outcome)
            pendingEstimate = nil
            Task { @MainActor [weak delegate] in delegate?.pipelineShotResolved(shot) }

        case nil:
            break
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

    private func makeShot(from outcome: ShotTracker.Outcome) -> DetectedShot {
        let estimate = pendingEstimate
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

        return DetectedShot(result: outcome.result,
                            confidence: outcome.confidence,
                            courtX: position?.courtX ?? 0.5,
                            courtY: position?.courtY ?? 0.5,
                            zone: zone,
                            distanceFt: estimate?.distanceFt,
                            science: science,
                            videoOffset: recorder?.startTime.map { max(0, outcome.release.time - $0) })
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
    /// shot-eval): all ball candidates, the raw rim, the crop and the call.
    private func logTelemetry(_ scene: SceneDetection, region: CGRect?,
                              event: ShotTracker.Event?, now: Double) {
        guard let logger = detectionLogger else { return }
        if sessionStartTime == nil { sessionStartTime = now }
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
        logger.log(entry)
    }
}
