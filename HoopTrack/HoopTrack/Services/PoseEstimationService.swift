// HoopTrack/Services/PoseEstimationService.swift
// Synchronous Vision body pose detector.
// Must be called on the camera session queue (same queue as CVPipeline).

import Vision
import AVFoundation

final class PoseEstimationService {

    /// Runs VNDetectHumanBodyPoseRequest on a single frame.
    /// Returns the first body pose observation, or nil if none detected or Vision fails.
    /// Synchronous — blocks the calling queue for < 5ms on A15.
    func detectPose(buffer: CMSampleBuffer) -> VNHumanBodyPoseObservation? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        try? handler.perform([request])
        return request.results?.first
    }
}
