// HoopTrack/Services/CourtCalibrationService.swift
// Tracks the basketball rim on a per-frame basis using detections from the
// ML ball detector's `basket` class. Replaces the earlier rectangle-heuristic
// approach (VNDetectRectanglesRequest + 10-frame lock), which couldn't tell
// a hoop from a poster and never recovered from camera movement.

import AVFoundation
import CoreGraphics

nonisolated enum CalibrationState: Sendable, Equatable {
    /// No basket has been seen yet.
    case looking
    /// Basket is currently in-frame and the smoother has a rect.
    case tracking(hoopRect: CGRect)
    /// Recently lost tracking — last-known rect is still available as a fallback.
    case lost(lastKnownHoopRect: CGRect)

    var isTracking: Bool {
        if case .tracking = self { return true }
        return false
    }

    /// Either the live tracked rect or the last-known one during a temporary drop-out.
    var hoopRect: CGRect? {
        switch self {
        case .looking:                       return nil
        case .tracking(let r):               return r
        case .lost(let r):                   return r
        }
    }
}

nonisolated final class CourtCalibrationService {

    // MARK: - State
    private(set) var state: CalibrationState = .looking
    private var smoother: HoopRectSmoother

    /// Callback fired on main thread when state changes — observed by LiveSessionViewModel.
    var onStateChange: (@Sendable (CalibrationState) -> Void)?

    // MARK: - Init

    init(smoother: HoopRectSmoother = HoopRectSmoother()) {
        self.smoother = smoother
    }

    // MARK: - Lifecycle

    func reset() {
        smoother.reset()
        transition(to: .looking)
    }

    // MARK: - Per-Frame Input
    // Called on the camera's sessionQueue with the basket detection for this frame
    // (nil when no basket was detected).

    func updateBasket(_ basket: BallDetection?, timestamp: CMTime) {
        let ts = CMTimeGetSeconds(timestamp)
        if let basket {
            smoother.update(basketRect: basket.boundingBox, timestamp: ts)
        } else {
            smoother.updateNoDetection(timestamp: ts)
        }

        let next: CalibrationState
        switch smoother.state {
        case .looking:
            next = .looking
        case .tracking:
            next = .tracking(hoopRect: smoother.smoothedRect ?? .zero)
        case .lost:
            next = .lost(lastKnownHoopRect: smoother.smoothedRect ?? .zero)
        }

        if next != state { transition(to: next) }
    }

    // MARK: - Court Coordinate Mapping

    /// Maps a ball bounding box (Vision normalised coords) to normalised court position (0–1).
    /// Uses the current or last-known hoop rect. Returns nil only when no rim has ever been seen.
    func courtPosition(for ballBox: CGRect) -> (courtX: Double, courtY: Double)? {
        guard let hoopRect = state.hoopRect else { return nil }

        let ballCX = ballBox.midX
        let ballCY = ballBox.midY

        // Horizontal: positive offset from hoop centre maps to court right
        let rawX = (ballCX - hoopRect.midX) / hoopRect.width * 0.5 + 0.5
        // Vertical: ball below hoop (lower Y in Vision) = closer to baseline (lower courtY)
        let rawY = max(0, hoopRect.midY - ballCY) / hoopRect.height * 0.5

        return (
            courtX: Double(rawX).clamped(to: 0...1),
            courtY: Double(rawY).clamped(to: 0...1)
        )
    }

    // MARK: - Private

    private func transition(to newState: CalibrationState) {
        state = newState
        let callback = onStateChange
        Task { @MainActor in
            callback?(newState)
        }
    }
}
