// HoopTrack/Services/DribblePipeline.swift
// Counts dribbles from the front camera. Runs on the camera's session queue.
//
// Body pose (not hand pose): at 2–3 m from the phone, hands are too small
// for VNDetectHumanHandPoseRequest, but body-pose wrists stay reliable.
// Each wrist feeds a WristBounceDetector, which needs a push of at least
// 12% of torso length — so jitter and small hand wobbles don't count.
//
// The previous ARKit version handed Vision the sensor-orientation frame
// with `.up`, so in portrait the wrist's "y" was actually side-to-side
// motion; it also ran Vision on the main thread.

@preconcurrency import Vision
import AVFoundation
import Combine
import Foundation

@MainActor protocol DribblePipelineDelegate: AnyObject, Sendable {
    func pipeline(didUpdate metrics: DribbleLiveMetrics)
}

nonisolated final class DribblePipeline: @unchecked Sendable {

    nonisolated(unsafe) private weak var delegate: DribblePipelineDelegate?
    nonisolated(unsafe) private var cancellable: AnyCancellable?
    nonisolated(unsafe) private let request = VNDetectHumanBodyPoseRequest()

    nonisolated(unsafe) private var left = WristBounceDetector(threshold: HoopTrack.Dribble.bounceThresholdTorso)
    nonisolated(unsafe) private var right = WristBounceDetector(threshold: HoopTrack.Dribble.bounceThresholdTorso)
    nonisolated(unsafe) private var metrics = DribbleLiveMetrics()
    nonisolated(unsafe) private var hands: [DribbleCalculator.HandSide] = []
    nonisolated(unsafe) private var recent: [Double] = []
    nonisolated(unsafe) private var lastPublish: Double = 0
    nonisolated(unsafe) private var lastProcessed: Double = 0

    /// Paused frames are dropped entirely.
    nonisolated(unsafe) var isPaused = false

    func start(framePublisher: AnyPublisher<CMSampleBuffer, Never>, delegate: DribblePipelineDelegate) {
        self.delegate = delegate
        cancellable = framePublisher.sink { [weak self] buffer in
            self?.process(buffer)
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    private func process(_ buffer: CMSampleBuffer) {
        guard !isPaused, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let now = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
        // ~30 fps is plenty for up to 10 dribbles a second and halves the cost.
        guard now - lastProcessed >= 1.0 / 32 else { return }
        lastProcessed = now

        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        try? handler.perform([request])
        let pose = request.results?.first

        var dribbled = false
        if let pose, let torso = torsoLength(pose) {
            metrics.isPlayerVisible = true
            if let y = wristY(pose, .leftWrist), left.update(y: y, torso: torso) {
                count(.left, at: now); dribbled = true
            }
            if let y = wristY(pose, .rightWrist), right.update(y: y, torso: torso) {
                count(.right, at: now); dribbled = true
            }
        } else {
            metrics.isPlayerVisible = false
        }

        recent.removeAll { now - $0 > HoopTrack.Dribble.bpsWindowSec }
        metrics.currentBPS = Double(recent.count) / HoopTrack.Dribble.bpsWindowSec
        metrics.maxBPS = max(metrics.maxBPS, metrics.currentBPS)

        guard dribbled || now - lastPublish > 0.2 else { return }
        lastPublish = now
        let snapshot = metrics
        Task { @MainActor [weak delegate] in delegate?.pipeline(didUpdate: snapshot) }
    }

    private func count(_ hand: DribbleCalculator.HandSide, at time: Double) {
        metrics.totalDribbles += 1
        switch hand {
        case .left:  metrics.leftHandDribbles += 1
        case .right: metrics.rightHandDribbles += 1
        }
        if let last = hands.last, last != hand { metrics.combosDetected += 1 }
        hands.append(hand)
        if hands.count > 8 { hands.removeFirst(hands.count - 8) }
        metrics.lastActiveHand = hand
        recent.append(time)
    }

    private func wristY(_ pose: VNHumanBodyPoseObservation,
                        _ joint: VNHumanBodyPoseObservation.JointName) -> Double? {
        guard let point = try? pose.recognizedPoint(joint), point.confidence > 0.3 else { return nil }
        return Double(point.location.y)
    }

    /// Neck → hip centre, in normalised image height.
    private func torsoLength(_ pose: VNHumanBodyPoseObservation) -> Double? {
        guard let neck = try? pose.recognizedPoint(.neck), neck.confidence > 0.3,
              let root = try? pose.recognizedPoint(.root), root.confidence > 0.3 else { return nil }
        let length = Double(abs(neck.location.y - root.location.y))
        return length > 0.05 ? length : nil
    }
}
