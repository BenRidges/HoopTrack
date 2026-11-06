// HoopTrack/Utilities/HoopRectSmoother.swift
// Pure value-type EMA smoother for per-frame hoop bounding boxes.
// Stateless-ish — holds only the last smoothed rect + last-seen timestamp.
// Replaces the 10-frame-accumulation lock in the previous CourtCalibrationService.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated struct HoopRectSmoother: Sendable {

    enum State: Sendable, Equatable {
        /// No basket ever seen.
        case looking
        /// Recent basket detection; smoothedRect is current.
        case tracking
        /// No detection for longer than lostTimeoutSec. Last-known rect preserved.
        case lost
    }

    /// Exponential-moving-average factor. Higher = more responsive to new
    /// detections; lower = smoother but laggier. 0.4 keeps jitter low while
    /// reacting within ~3 frames to real phone movement at 60 fps.
    let alpha: Double

    /// How long since the last basket detection before transitioning to `lost`.
    /// 0.5 s covers a typical hand-over-lens occlusion without prematurely
    /// tearing down the known rect.
    let lostTimeoutSec: Double

    private(set) var state: State = .looking
    private(set) var smoothedRect: CGRect?
    private var lastSeenTimestamp: Double = 0

    init(alpha: Double = 0.4, lostTimeoutSec: Double = 0.5) {
        self.alpha = alpha
        self.lostTimeoutSec = lostTimeoutSec
    }

    /// Call when a basket detection is produced for the current frame.
    mutating func update(basketRect: CGRect, timestamp: Double) {
        let next: CGRect
        switch state {
        case .looking, .lost:
            // Fresh start — snap to the new rect rather than blending with
            // stale or nil state.
            next = basketRect
        case .tracking:
            next = ema(from: smoothedRect ?? basketRect, to: basketRect, alpha: alpha)
        }

        smoothedRect = next
        lastSeenTimestamp = timestamp
        state = .tracking
    }

    /// Call once per frame when no basket was detected.
    mutating func updateNoDetection(timestamp: Double) {
        guard state == .tracking else { return }
        if timestamp - lastSeenTimestamp > lostTimeoutSec {
            state = .lost
        }
    }

    mutating func reset() {
        state = .looking
        smoothedRect = nil
        lastSeenTimestamp = 0
    }

    /// Which of this frame's hoop detections is the one being tracked.
    ///
    /// Gyms often have more than one basket in view. Taking the most
    /// confident box each frame made the smoother average two hoops into a
    /// box between them. Instead: while tracking, only a box overlapping the
    /// current one counts; otherwise (first sighting, or lost after the
    /// phone moved) take the biggest box — the nearest hoop, the one the
    /// camera was set up for.
    func choose(from candidates: [CGRect]) -> CGRect? {
        let valid = candidates.filter { $0.width > 0 && $0.height > 0 }
        if state == .tracking, let current = smoothedRect {
            let best = valid.map { ($0, Self.overlap($0, current)) }.max { $0.1 < $1.1 }
            return best.flatMap { $0.1 >= 0.2 ? $0.0 : nil }
        }
        return valid.max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Intersection over union.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard w > 0, h > 0 else { return 0 }
        let inter = Double(w * h)
        let union = Double(a.width * a.height + b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }

    // MARK: - Private

    private func ema(from a: CGRect, to b: CGRect, alpha: Double) -> CGRect {
        let blend: (Double, Double) -> Double = { old, new in (1 - alpha) * old + alpha * new }
        return CGRect(
            x:      blend(a.origin.x, b.origin.x),
            y:      blend(a.origin.y, b.origin.y),
            width:  blend(a.width,    b.width),
            height: blend(a.height,   b.height)
        )
    }
}
