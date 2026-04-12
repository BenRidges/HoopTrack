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

    // Per-hand wrist tracking state — @MainActor-isolated; mutated inside Task { @MainActor in }
    private var leftState  = WristState()
    private var rightState = WristState()

    // Rolling BPS window (last 3 seconds worth of dribble timestamps)
    private var dribbleTimestamps: [Double] = []  // seconds since session start
    private var sessionStartTime: Double = 0

    private var metrics = DribbleLiveMetrics()

    // Combo tracking: ordered history of which hand dribbled last
    private var handHistory: [DribbleCalculator.HandSide] = []

    // MARK: - Session

    /// Call this before starting the ARSession. The AR session must not be delivering
    /// frames yet — the reset dispatches asynchronously to main, so in-flight frames
    /// processed after this call but before the dispatch executes will use stale state.
    nonisolated func startSession(at startTime: Double) {
        Task { @MainActor [weak self] in
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

        // Single recognizedPoint lookup per hand — feeds both detection and rendering paths.
        struct WristSample { var y: Double; var position: CGPoint }

        func sample(from obs: VNHumanHandPoseObservation?) -> WristSample? {
            guard let obs,
                  let pt = try? obs.recognizedPoint(.wrist),
                  pt.confidence > 0.3 else { return nil }
            return WristSample(y: Double(pt.location.y),
                               position: CGPoint(x: pt.location.x, y: pt.location.y))
        }

        let leftSample  = sample(from: leftObs)
        let rightSample = sample(from: rightObs)

        // Pass wrist Y scalars to main; WristState mutation happens there under @MainActor isolation.
        let leftY       = leftSample?.y
        let rightY      = rightSample?.y
        let newLeftPos  = leftSample?.position   // nil when hand not visible
        let newRightPos = rightSample?.position

        Task { @MainActor [weak self] in
            guard let self else { return }
            // sessionStartTime is @MainActor-isolated — safe to read here.
            let t = timestamp - self.sessionStartTime
            let leftDribble  = leftY.map  { self.leftState.update(y: $0)  } ?? false
            let rightDribble = rightY.map { self.rightState.update(y: $0) } ?? false

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

            // Prune timestamps outside the rolling BPS window.
            let window = HoopTrack.Dribble.bpsWindowSec
            self.dribbleTimestamps = self.dribbleTimestamps.filter { t - $0 <= window }
            let currentBPS = Double(self.dribbleTimestamps.count) / window
            self.metrics.currentBPS = currentBPS
            if currentBPS > self.metrics.maxBPS { self.metrics.maxBPS = currentBPS }

            self.metrics.combosDetected = DribbleCalculator.comboCount(
                handHistory: self.handHistory)

            self.delegate?.pipeline(self, didUpdate: self.metrics)
        }
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
