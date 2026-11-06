// HoopTrack/Services/CourtCalibrationService.swift
// Tracks the rim per frame using the detector's hoop class, smoothed by
// HoopRectSmoother (EMA, 0.5 s lost timeout). Runs on the camera queue.

import AVFoundation
import CoreGraphics

nonisolated enum CalibrationState: Sendable, Equatable {
    /// No hoop has been seen yet.
    case looking
    /// Hoop is in frame and the smoother has a rect.
    case tracking(hoopRect: CGRect)
    /// Briefly lost — last-known rect stays usable as a fallback.
    case lost(lastKnownHoopRect: CGRect)

    var isTracking: Bool {
        if case .tracking = self { return true }
        return false
    }

    /// The live rect, or the last-known one during a short drop-out.
    var hoopRect: CGRect? {
        switch self {
        case .looking:         return nil
        case .tracking(let r): return r
        case .lost(let r):     return r
        }
    }
}

nonisolated final class CourtCalibrationService {

    private(set) var state: CalibrationState = .looking
    private var smoother: HoopRectSmoother

    init(smoother: HoopRectSmoother = HoopRectSmoother()) {
        self.smoother = smoother
    }

    func reset() {
        smoother.reset()
        state = .looking
    }

    /// Called once per frame with that frame's hoop detections (may be empty).
    func updateBaskets(_ baskets: [BallDetection], timestamp: CMTime) {
        let ts = CMTimeGetSeconds(timestamp)
        if let rect = smoother.choose(from: baskets.map(\.boundingBox)) {
            smoother.update(basketRect: rect, timestamp: ts)
        } else {
            smoother.updateNoDetection(timestamp: ts)
        }

        switch smoother.state {
        case .looking:  state = .looking
        case .tracking: state = .tracking(hoopRect: smoother.smoothedRect ?? .zero)
        case .lost:     state = .lost(lastKnownHoopRect: smoother.smoothedRect ?? .zero)
        }
    }
}
