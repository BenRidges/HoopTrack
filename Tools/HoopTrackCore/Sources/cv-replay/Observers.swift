// Observers.swift
// What cv-replay attaches to the pipeline to watch it, without changing
// what it does:
//
//   FrameClock         — which frame the session queue is on, so each
//                        delegate call can be pinned to the frame that
//                        caused it.
//   RecordingDelegate  — the ShotPipelineDelegate, recording every call
//                        exactly as LiveSessionViewModel would receive it.
//   DetectorProbe      — passes every call straight to CoreMLBallDetector
//                        and returns its result untouched; it only notes the
//                        inference time and the hoop candidates.

import CoreGraphics
import CoreMedia
import Foundation
@testable import HoopTrack

/// The frame currently being processed on the session queue.
final class FrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var index = -1
    private var pts = 0.0

    func set(index: Int, pts: Double) {
        lock.lock(); defer { lock.unlock() }
        self.index = index
        self.pts = pts
    }

    var current: (index: Int, pts: Double) {
        lock.lock(); defer { lock.unlock() }
        return (index, pts)
    }
}

@MainActor final class RecordingDelegate: ShotPipelineDelegate {

    struct Shot {
        /// Fed-frame index and PTS (video seconds) of the frame whose
        /// processing published this call.
        let frame: Int
        let pts: Double
        let shot: DetectedShot
    }

    struct HoopChange {
        let frame: Int
        let pts: Double
        let state: CalibrationState

        /// 0 looking, 1 tracking, 2 lost — as CVPipeline.publishHoop counts.
        var kind: Int {
            switch state {
            case .looking:  return 0
            case .tracking: return 1
            case .lost:     return 2
            }
        }
    }

    private let clock: FrameClock
    private(set) var shots: [Shot] = []
    private(set) var starts: [(frame: Int, pts: Double)] = []
    private(set) var hoopChanges: [HoopChange] = []
    private(set) var ballMoves = 0

    init(clock: FrameClock) {
        self.clock = clock
    }

    deinit {}

    /// Every call so far, for checking the main actor has caught up.
    var callCount: Int { shots.count + starts.count + hoopChanges.count + ballMoves }

    func pipelineHoopChanged(_ state: CalibrationState) {
        let now = clock.current
        hoopChanges.append(HoopChange(frame: now.index, pts: now.pts, state: state))
    }

    func pipelineBallMoved(_ box: CGRect?) {
        ballMoves += 1
    }

    func pipelineShotStarted() {
        let now = clock.current
        starts.append((now.index, now.pts))
    }

    func pipelineShotResolved(_ shot: DetectedShot) {
        let now = clock.current
        shots.append(Shot(frame: now.index, pts: now.pts, shot: shot))
    }
}

/// Transparent wrapper around the real detector.
final class DetectorProbe: BallDetectorProtocol, @unchecked Sendable {

    struct FrameStat {
        let pts: Double
        let region: CGRect?
        /// Every hoop the detector returned, most confident first.
        let baskets: [(box: CGRect, confidence: Float)]
        let ballCount: Int
        let inferenceMs: Double
    }

    private let inner: BallDetectorProtocol
    /// Touched only from the session queue (the pipeline's contract).
    private(set) var stats: [FrameStat] = []

    init(wrapping inner: BallDetectorProtocol) {
        self.inner = inner
    }

    func detectScene(buffer: CMSampleBuffer, region: CGRect?) -> SceneDetection? {
        let start = DispatchTime.now().uptimeNanoseconds
        let scene = inner.detectScene(buffer: buffer, region: region)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        stats.append(FrameStat(pts: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)),
                               region: region,
                               baskets: scene?.baskets.map { ($0.boundingBox, $0.confidence) } ?? [],
                               ballCount: scene?.balls.count ?? 0,
                               inferenceMs: elapsed))
        return scene
    }
}
