// HoopTrack/Services/CourtCalibrationService.swift
// Detects the backboard/hoop rectangle via Vision and locks a reference CGRect
// used by CVPipeline to map ball positions to normalised court coordinates.

import Vision
import AVFoundation
import CoreGraphics

enum CalibrationState {
    case uncalibrated
    case detecting
    case calibrated(hoopRect: CGRect)
    case failed(reason: String)

    var isCalibrated: Bool {
        if case .calibrated = self { return true }
        return false
    }
}

final class CourtCalibrationService {

    // MARK: - State
    private(set) var state: CalibrationState = .uncalibrated

    // Callback fired on main thread when state changes — observed by LiveSessionViewModel.
    var onStateChange: ((CalibrationState) -> Void)?

    // MARK: - Vision
    private let request: VNDetectRectanglesRequest = {
        let r = VNDetectRectanglesRequest()
        r.minimumAspectRatio    = 1.5
        r.maximumAspectRatio    = 5.0
        r.minimumConfidence     = 0.6
        r.maximumObservations   = 3
        return r
    }()

    // Accumulate candidate rects across frames before locking
    private var candidates: [CGRect] = []
    private let framesNeeded = 10

    // MARK: - Lifecycle

    func startCalibration() {
        candidates = []
        setState(.detecting)
    }

    func reset() {
        candidates = []
        setState(.uncalibrated)
    }

    // MARK: - Frame Processing
    // Called on the camera's sessionQueue (background thread).

    func processFrame(_ buffer: CMSampleBuffer) {
        guard case .detecting = state,
              let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        try? handler.perform([request])

        guard let results = request.results as? [VNRectangleObservation],
              let best    = results.max(by: { $0.boundingBox.width < $1.boundingBox.width })
        else { return }

        candidates.append(best.boundingBox)
        if candidates.count >= framesNeeded {
            let avgRect = averaged(candidates)
            setState(.calibrated(hoopRect: avgRect))
        }
    }

    // MARK: - Court Coordinate Mapping

    /// Maps a ball bounding box (Vision normalised coords) to normalised court position (0–1).
    /// Returns nil if calibration is not complete.
    func courtPosition(for ballBox: CGRect) -> (courtX: Double, courtY: Double)? {
        guard case .calibrated(let hoopRect) = state else { return nil }

        let ballCX = ballBox.midX
        let ballCY = ballBox.midY

        // Horizontal: positive offset from hoop centre maps to court right
        let rawX = (ballCX - hoopRect.midX) / hoopRect.width * 0.5 + 0.5
        // Vertical: ball below hoop (lower Y in Vision) = closer to baseline (lower courtY)
        let rawY = max(0, hoopRect.midY - ballCY) / hoopRect.height * 0.5

        return (
            courtX: rawX.clamped(to: 0...1),
            courtY: rawY.clamped(to: 0...1)
        )
    }

    // MARK: - Private

    private func setState(_ newState: CalibrationState) {
        state = newState
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStateChange?(self.state)
        }
    }

    private func averaged(_ rects: [CGRect]) -> CGRect {
        let n = Double(rects.count)
        return CGRect(
            x:      rects.map(\.minX).reduce(0, +) / n,
            y:      rects.map(\.minY).reduce(0, +) / n,
            width:  rects.map(\.width).reduce(0, +) / n,
            height: rects.map(\.height).reduce(0, +) / n
        )
    }
}
