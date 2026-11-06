// HoopTrack/ML/BallDetectorProtocol.swift
import AVFoundation
import CoreGraphics

/// A single detection from one camera frame — used for both ball and hoop.
/// Vision-normalised coordinates: origin bottom-left, 0–1 range.
nonisolated struct BallDetection: Sendable {
    let boundingBox: CGRect
    let confidence: Float
    let frameTimestamp: CMTime
}

/// Everything of interest from one frame. `balls` holds every ball candidate
/// (highest confidence first) so the tracker can follow the right one when
/// there are several balls on court.
nonisolated struct SceneDetection: Sendable {
    let balls: [BallDetection]
    let basket: BallDetection?
    let frameTimestamp: CMTime

    /// Most confident ball, for logging and the debug overlay.
    var ball: BallDetection? { balls.first }
}

/// Implemented by the Core ML wrapper and the debug stub. Called on the
/// camera's session queue — must not touch the main actor.
nonisolated protocol BallDetectorProtocol: Sendable {
    /// Detects in `region` (Vision-normalised; nil = whole frame). Boxes in
    /// the result are always full-frame coordinates.
    func detectScene(buffer: CMSampleBuffer, region: CGRect?) -> SceneDetection?
}

nonisolated extension BallDetectorProtocol {
    func detectScene(buffer: CMSampleBuffer) -> SceneDetection? {
        detectScene(buffer: buffer, region: nil)
    }
}
