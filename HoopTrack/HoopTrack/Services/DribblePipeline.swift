// HoopTrack/Services/DribblePipeline.swift
// Processes ARKit frames to detect dribble events via Vision hand tracking.
// Runs on the ARSession delegate queue (background).
// Publishes DribbleLiveMetrics updates to DribbleSessionViewModel on the main thread.
//
// Dribble detection algorithm:
//   - Track wrist Y position per hand across frames.
//   - A dribble is counted when wrist Y transitions from descending to ascending
//     (local minimum = ball contact with floor).
//   - Requires `velocityConfirmFrames` consecutive frames in each direction
//     to suppress noise.

import Vision
import RealityKit
import CoreVideo

@MainActor
protocol DribblePipelineDelegate: AnyObject {
    func pipeline(_ pipeline: DribblePipeline, didUpdate metrics: DribbleLiveMetrics)
}

final class DribblePipeline {

    weak var delegate: DribblePipelineDelegate?

    private let handService = HandTrackingService()

    // Per-hand wrist tracking state
    nonisolated(unsafe) private var leftState  = WristState()
    nonisolated(unsafe) private var rightState = WristState()

    // Rolling BPS window (last 3 seconds worth of dribble timestamps)
    private var dribbleTimestamps: [Double] = []  // seconds since session start
    nonisolated(unsafe) private var sessionStartTime: Double = 0

    private var metrics = DribbleLiveMetrics()

    // Combo tracking: ordered history of which hand dribbled last
    private var handHistory: [DribbleCalculator.HandSide] = []

    // MARK: - Session

    nonisolated func startSession(at startTime: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.sessionStartTime = startTime
            self?.metrics = DribbleLiveMetrics()
            self?.dribbleTimestamps = []
            self?.leftState  = WristState()
            self?.rightState = WristState()
            self?.handHistory = []
        }
    }

    // MARK: - Frame Processing (call from ARSessionDelegate, background queue)

    nonisolated func processFrame(pixelBuffer: CVPixelBuffer,
                                  timestamp: Double) {
        let observations = handService.detectHands(pixelBuffer: pixelBuffer)
        var leftObs:  VNHumanHandPoseObservation? = nil
        var rightObs: VNHumanHandPoseObservation? = nil

        for obs in observations {
            if obs.chirality == .left  { leftObs  = obs }
            if obs.chirality == .right { rightObs = obs }
        }

        let leftWrist  = wristY(from: leftObs)
        let rightWrist = wristY(from: rightObs)

        var newLeftPos:  CGPoint? = nil
        var newRightPos: CGPoint? = nil

        if let lp = leftObs.flatMap({ try? $0.recognizedPoint(.wrist) }), lp.confidence > 0.3 {
            newLeftPos = CGPoint(x: lp.location.x, y: lp.location.y)
        }
        if let rp = rightObs.flatMap({ try? $0.recognizedPoint(.wrist) }), rp.confidence > 0.3 {
            newRightPos = CGPoint(x: rp.location.x, y: rp.location.y)
        }

        var leftDribble  = false
        var rightDribble = false

        if let y = leftWrist  { leftDribble  = leftState.update(y: y)  }
        if let y = rightWrist { rightDribble = rightState.update(y: y) }

        let t = timestamp - sessionStartTime

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if leftDribble {
                self.metrics.totalDribbles     += 1
                self.metrics.leftHandDribbles  += 1
                self.metrics.lastActiveHand     = .left
                self.handHistory.append(.left)
                self.dribbleTimestamps.append(t)
            }
            if rightDribble {
                self.metrics.totalDribbles     += 1
                self.metrics.rightHandDribbles += 1
                self.metrics.lastActiveHand     = .right
                self.handHistory.append(.right)
                self.dribbleTimestamps.append(t)
            }

            self.metrics.leftWristPosition  = newLeftPos
            self.metrics.rightWristPosition = newRightPos

            // Prune timestamps older than 3 seconds
            self.dribbleTimestamps = self.dribbleTimestamps.filter { t - $0 <= 3.0 }
            let currentBPS = Double(self.dribbleTimestamps.count) / 3.0
            self.metrics.currentBPS = currentBPS
            if currentBPS > self.metrics.maxBPS { self.metrics.maxBPS = currentBPS }

            self.metrics.combosDetected = DribbleCalculator.comboCount(
                handHistory: self.handHistory)

            self.delegate?.pipeline(self, didUpdate: self.metrics)
        }
    }

    // MARK: - Helpers

    nonisolated private func wristY(from obs: VNHumanHandPoseObservation?) -> Double? {
        guard let obs,
              let wrist = try? obs.recognizedPoint(.wrist),
              wrist.confidence > 0.3 else { return nil }
        return Double(wrist.location.y)
    }
}

// MARK: - WristState

/// Tracks wrist Y velocity to detect the upward turn at the bottom of a dribble.
private struct WristState {
    private var previousY: Double?
    private var descendingFrames: Int = 0
    private var ascendingFrames:  Int = 0
    private let confirmFrames = HoopTrack.Dribble.velocityConfirmFrames

    /// Returns true when a dribble bounce is confirmed (wrist just turned upward
    /// after at least `confirmFrames` descending frames).
    mutating func update(y: Double) -> Bool {
        defer { previousY = y }
        guard let prev = previousY else { return false }

        let dy = y - prev  // positive = moving up in Vision coords

        if dy < 0 {
            // Descending
            descendingFrames += 1
            ascendingFrames   = 0
        } else if dy > 0 {
            // Ascending
            ascendingFrames += 1
            if ascendingFrames >= confirmFrames && descendingFrames >= confirmFrames {
                // Confirmed bounce: reset and count
                descendingFrames = 0
                ascendingFrames  = 0
                return true
            }
        }
        return false
    }
}
