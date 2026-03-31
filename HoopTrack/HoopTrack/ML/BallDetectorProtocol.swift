// HoopTrack/ML/BallDetectorProtocol.swift
import AVFoundation
import CoreGraphics

/// A single ball detection result from one camera frame.
struct BallDetection {
    /// Bounding box in Vision normalised coordinates: origin bottom-left, 0–1 range.
    let boundingBox: CGRect
    /// Model confidence score 0–1.
    let confidence: Float
    /// Presentation timestamp of the source frame, used for trajectory timing.
    let frameTimestamp: CMTime
}

/// Protocol that both the real Core ML wrapper and the debug stub conform to.
/// Kept on the background session queue — must NOT touch the main actor.
protocol BallDetectorProtocol {
    func detect(buffer: CMSampleBuffer) -> BallDetection?
}
