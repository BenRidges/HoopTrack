// HoopTrack/Services/HandTrackingService.swift
// Synchronous Vision hand pose detector.
// Returns up to two VNHumanHandPoseObservation (one per hand).
// Must be called on a background queue (e.g. ARSession delegate queue).

import Vision
import CoreVideo

final class HandTrackingService {

    /// Detects up to 2 hand poses in a single pixel buffer.
    /// Synchronous — blocks calling queue for < 5ms on A15.
    nonisolated func detectHands(pixelBuffer: CVPixelBuffer) -> [VNHumanHandPoseObservation] {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        try? handler.perform([request])
        return request.results ?? []
    }
}
