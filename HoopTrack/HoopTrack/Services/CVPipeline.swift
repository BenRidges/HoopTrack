// HoopTrack/Services/CVPipeline.swift
// Subscribes to CameraService.framePublisher and runs the shot-detection
// state machine. All Vision work and trajectory maths run on the camera's
// sessionQueue. Calls @MainActor methods on LiveSessionViewModel for shot logging.

import AVFoundation
import Combine
import CoreGraphics
import Foundation

// MARK: - Internal State

private enum PipelineState: Sendable {
    case idle
    case tracking(trajectory: [BallDetection])
    case releaseDetected(releaseBox: CGRect, trajectory: [BallDetection])
}

// MARK: - CVPipeline

/// Runs on the camera's sessionQueue. All mutable state is accessed only from
/// the Combine sink closure, which Combine delivers synchronously on the same
/// serial queue that calls `frameSubject.send(...)` in CameraService. The
/// `nonisolated(unsafe)` annotations record that the compiler cannot prove
/// this serialisation but it holds at runtime.
nonisolated final class CVPipeline {

    // MARK: - Dependencies
    private let detector:    BallDetectorProtocol
    private let calibration: CourtCalibrationService
    private let poseService: PoseEstimationService?
    nonisolated(unsafe) private weak var viewModel: LiveSessionViewModel?

    // MARK: - State
    nonisolated(unsafe) private var pipelineState: PipelineState = .idle
    nonisolated(unsafe) private var frameCancellable: AnyCancellable?

    // Tracking: if no ball seen for 0.3s, return to IDLE
    nonisolated(unsafe) private var lastDetectionTimestamp: CMTime = .zero
    private let trackingTimeoutSec: Double = 0.3

    // Release resolved: 2s timeout → MISS
    nonisolated(unsafe) private var releaseTimestamp: CMTime = .zero
    private let shotTimeoutSec: Double = 2.0

    // MARK: - Init
    init(detector: BallDetectorProtocol,
         calibration: CourtCalibrationService,
         poseService: PoseEstimationService? = nil) {
        self.detector    = detector
        self.calibration = calibration
        self.poseService = poseService
    }

    // MARK: - Lifecycle

    func start(framePublisher: AnyPublisher<CMSampleBuffer, Never>,
                           viewModel: LiveSessionViewModel) {
        self.viewModel = viewModel
        // Frames arrive on sessionQueue — CV work stays there; UI calls dispatch to main.
        frameCancellable = framePublisher
            .sink { [weak self] buffer in
                self?.processBuffer(buffer)
            }
    }

    func stop() {
        frameCancellable?.cancel()
        frameCancellable = nil
        pipelineState = .idle
    }

    // MARK: - Core Frame Processing

    private func processBuffer(_ buffer: CMSampleBuffer) {
        guard let scene = detector.detectScene(buffer: buffer) else { return }
        let now = scene.frameTimestamp

        // Feed the basket detection to calibration every frame — the
        // smoother handles jitter and missed frames internally.
        calibration.updateBasket(scene.basket, timestamp: now)

        // Push ball detection to the debug overlay.
        let overlayBox = scene.ball?.boundingBox
        let overlayConfidence = scene.ball?.confidence
        Task { @MainActor [weak viewModel] in
            viewModel?.updateBallDetection(box: overlayBox, confidence: overlayConfidence)
        }

        // Shot detection requires a tracked (or recently-tracked) hoop rect.
        guard let hoopRect = calibration.state.hoopRect else { return }

        let detection = scene.ball

        switch pipelineState {

        case .idle:
            if let d = detection {
                pipelineState = .tracking(trajectory: [d])
                lastDetectionTimestamp = now
            }

        case .tracking(var trajectory):
            if let d = detection {
                trajectory.append(d)
                lastDetectionTimestamp = now

                if isAtPeak(trajectory: trajectory) {
                    let releaseBox = trajectory.first!.boundingBox

                    // Phase 3: compute Shot Science synchronously on the session queue
                    let science: ShotScienceMetrics?
                    if let ps = poseService {
                        let observation = ps.detectPose(buffer: buffer)
                        science = ShotScienceCalculator.compute(
                            trajectory: trajectory,
                            poseObservation: observation,
                            hoopRectWidth: hoopRect.width
                        )
                    } else {
                        science = nil
                    }

                    pipelineState    = .releaseDetected(releaseBox: releaseBox, trajectory: trajectory)
                    releaseTimestamp = now
                    logPendingShot(releaseBox: releaseBox, science: science)
                } else {
                    pipelineState = .tracking(trajectory: trajectory)
                }
            } else {
                let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, lastDetectionTimestamp))
                if elapsed > trackingTimeoutSec { pipelineState = .idle }
            }

        case .releaseDetected(let releaseBox, _):
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, releaseTimestamp))

            if let d = detection {
                if isEnteringHoop(ballBox: d.boundingBox, hoopRect: hoopRect) {
                    resolveShot(result: .make, releaseBox: releaseBox)
                    return
                }
                if isBelowHoop(ballBox: d.boundingBox, hoopRect: hoopRect) {
                    resolveShot(result: .miss, releaseBox: releaseBox)
                    return
                }
            }

            if elapsed > shotTimeoutSec {
                resolveShot(result: .miss, releaseBox: releaseBox)
            }
        }
    }

    // MARK: - Trajectory Analysis

    /// True when the ball has risen at least 5% of frame height and is now 3% below its peak.
    /// Vision Y coordinates: origin bottom-left, increasing upward.
    private func isAtPeak(trajectory: [BallDetection]) -> Bool {
        guard trajectory.count >= 5 else { return false }
        let ys      = trajectory.suffix(5).map { $0.boundingBox.midY }
        let peak    = ys.max()!
        let current = ys.last!
        let first   = ys.first!
        let wasRising = peak - first   > 0.05
        let hasPeaked = peak - current > 0.03
        return wasRising && hasPeaked
    }

    /// Ball centre is within an expanded hoop rect — indicates a make.
    private func isEnteringHoop(ballBox: CGRect, hoopRect: CGRect) -> Bool {
        let expanded   = hoopRect.insetBy(dx: -hoopRect.width  * 0.2,
                                          dy: -hoopRect.height * 0.5)
        let ballCentre = CGPoint(x: ballBox.midX, y: ballBox.midY)
        return expanded.contains(ballCentre)
    }

    /// Ball has fallen below the bottom edge of the hoop rect — indicates a miss.
    private func isBelowHoop(ballBox: CGRect, hoopRect: CGRect) -> Bool {
        return ballBox.midY < hoopRect.minY - 0.05
    }

    // MARK: - Shot Logging (dispatches to main actor)

    private func logPendingShot(releaseBox: CGRect, science: ShotScienceMetrics?) {
        let pos  = calibration.courtPosition(for: releaseBox) ?? (courtX: 0.5, courtY: 0.5)
        let zone = CourtZoneClassifier.classify(courtX: pos.courtX, courtY: pos.courtY)
        Task { @MainActor [weak self] in
            self?.viewModel?.logPendingShot(zone: zone,
                                            courtX: pos.courtX,
                                            courtY: pos.courtY,
                                            science: science)
        }
    }

    private func resolveShot(result: ShotResult, releaseBox: CGRect) {
        let pos  = calibration.courtPosition(for: releaseBox) ?? (courtX: 0.5, courtY: 0.5)
        let zone = CourtZoneClassifier.classify(courtX: pos.courtX, courtY: pos.courtY)
        pipelineState = .idle
        Task { @MainActor [weak self] in
            self?.viewModel?.resolvePendingShot(result: result,
                                                 zone: zone,
                                                 courtX: pos.courtX,
                                                 courtY: pos.courtY)
        }
    }
}
