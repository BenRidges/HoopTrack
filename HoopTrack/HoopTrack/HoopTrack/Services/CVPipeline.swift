// HoopTrack/Services/CVPipeline.swift
// Subscribes to CameraService.framePublisher and runs the shot-detection
// state machine. All Vision work and trajectory maths run on the camera's
// sessionQueue. Calls @MainActor methods on LiveSessionViewModel for shot logging.

import AVFoundation
import Combine
import CoreGraphics
import Foundation

// MARK: - Internal State

private enum PipelineState {
    case idle
    case tracking(trajectory: [BallDetection])
    case releaseDetected(releaseBox: CGRect, trajectory: [BallDetection])
}

// MARK: - CVPipeline

final class CVPipeline {

    // MARK: - Dependencies
    private let detector:    BallDetectorProtocol
    private let calibration: CourtCalibrationService
    private weak var viewModel: LiveSessionViewModel?

    // MARK: - State
    private var pipelineState: PipelineState = .idle
    private var frameCancellable: AnyCancellable?

    // Tracking: if no ball seen for 0.3s, return to IDLE
    private var lastDetectionTimestamp: CMTime = .zero
    private let trackingTimeoutSec: Double = 0.3

    // Release resolved: 2s timeout → MISS
    private var releaseTimestamp: CMTime = .zero
    private let shotTimeoutSec: Double = 2.0

    // MARK: - Init
    init(detector: BallDetectorProtocol, calibration: CourtCalibrationService) {
        self.detector    = detector
        self.calibration = calibration
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
        // Feed calibration during detecting phase
        calibration.processFrame(buffer)

        // Only run shot detection after hoop is locked
        guard calibration.state.isCalibrated else { return }

        let now       = CMSampleBufferGetPresentationTimeStamp(buffer)
        let detection = detector.detect(buffer: buffer)

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
                    pipelineState  = .releaseDetected(releaseBox: releaseBox,
                                                       trajectory: trajectory)
                    releaseTimestamp = now
                    logPendingShot(releaseBox: releaseBox)
                } else {
                    pipelineState = .tracking(trajectory: trajectory)
                }
            } else {
                let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, lastDetectionTimestamp))
                if elapsed > trackingTimeoutSec { pipelineState = .idle }
            }

        case .releaseDetected(let releaseBox, let trajectory):
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, releaseTimestamp))

            if let d = detection, case .calibrated(let hoopRect) = calibration.state {
                if isEnteringHoop(ballBox: d.boundingBox, hoopRect: hoopRect) {
                    resolveShot(result: .make, releaseBox: releaseBox)
                    return
                }
                if isBelowHoop(ballBox: d.boundingBox, hoopRect: hoopRect) {
                    resolveShot(result: .miss, releaseBox: releaseBox)
                    return
                }
                _ = trajectory  // reserved for Phase 3 Shot Science
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

    private func logPendingShot(releaseBox: CGRect) {
        let pos  = calibration.courtPosition(for: releaseBox) ?? (courtX: 0.5, courtY: 0.5)
        let zone = CourtZoneClassifier.classify(courtX: pos.courtX, courtY: pos.courtY)
        DispatchQueue.main.async { [weak self] in
            self?.viewModel?.logPendingShot(zone: zone, courtX: pos.courtX, courtY: pos.courtY)
        }
    }

    private func resolveShot(result: ShotResult, releaseBox: CGRect) {
        let pos  = calibration.courtPosition(for: releaseBox) ?? (courtX: 0.5, courtY: 0.5)
        let zone = CourtZoneClassifier.classify(courtX: pos.courtX, courtY: pos.courtY)
        pipelineState = .idle
        DispatchQueue.main.async { [weak self] in
            self?.viewModel?.resolvePendingShot(result: result,
                                                 zone: zone,
                                                 courtX: pos.courtX,
                                                 courtY: pos.courtY)
        }
    }
}
