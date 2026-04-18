// HoopTrack/ML/BallDetectorProtocol.swift
import AVFoundation
import CoreGraphics

/// A single detection from one camera frame — used for both ball and basket.
/// Vision-normalised coordinates: origin bottom-left, 0–1 range.
nonisolated struct BallDetection: Sendable {
    let boundingBox: CGRect
    let confidence: Float
    let frameTimestamp: CMTime
}

/// All detections of interest from a single frame inference. Either field
/// may be nil — no ball in frame, or hoop out of view — but the detector
/// always returns a `SceneDetection` when the frame was processed, so the
/// caller can distinguish "no detection this frame" from "frame skipped".
nonisolated struct SceneDetection: Sendable {
    let ball: BallDetection?
    let basket: BallDetection?
    let frameTimestamp: CMTime
}

/// Protocol that both the real Core ML wrapper and the debug stub conform to.
/// Kept on the background session queue — must NOT touch the main actor.
nonisolated protocol BallDetectorProtocol: Sendable {
    /// Single inference per frame, returns every class of interest.
    func detectScene(buffer: CMSampleBuffer) -> SceneDetection?
}
