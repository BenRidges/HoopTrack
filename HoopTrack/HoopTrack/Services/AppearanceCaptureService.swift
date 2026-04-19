// AppearanceCaptureService.swift
// Ingests CMSampleBuffers, runs Vision body-pose detection, and emits an
// AppearanceDescriptor once a high-confidence lock has held for
// HoopTrack.Game.registrationLockDurationSec seconds.
//
// Lock robustness: individual frames routinely fail (motion blur, AE shifts,
// brief occlusion). The service caches the last-known-good pose reading and
// coasts on it through up to `maxStaleFrames` bad frames in a row. Beyond
// that, the lock resets. Frame-count based rather than time-based so the
// tolerance stays the same regardless of actual frame rate.

import Foundation
import Combine
import Vision
import CoreImage
import AVFoundation
import ImageIO

@MainActor
final class AppearanceCaptureService: ObservableObject {

    @Published private(set) var lockProgress: Double = 0   // 0..1
    @Published private(set) var captured: AppearanceDescriptor?
    @Published private(set) var statusMessage: String = "Step in front of the camera."

    /// Live keypoint confidences for the 4 required joints. Exposed for debug
    /// overlays during on-device testing. Updated every processed frame;
    /// empty when Vision returns no body observation.
    @Published private(set) var debugKeypoints: [String: Float] = [:]

    /// Last successful pose + pixel buffer. Used to keep the timer running
    /// through transient bad frames and to supply a clean frame for histogram
    /// extraction at capture time.
    private struct GoodReading {
        let points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
        let pixelBuffer: CVPixelBuffer
    }
    private var lastGood: GoodReading?
    private var framesSinceLastGood: Int = 0

    private var lockStart: Date?
    private let minConfidence: Float = HoopTrack.Game.registrationMinBodyConfidence
    private let requiredDurationSec: Double = HoopTrack.Game.registrationLockDurationSec

    private let maxStaleFrames: Int = HoopTrack.Game.registrationMaxStaleFrames

    private static let requiredJoints: [VNHumanBodyPoseObservation.JointName] =
        [.leftShoulder, .rightShoulder, .leftHip, .rightHip]

    func reset() {
        lockStart = nil
        lockProgress = 0
        lastGood = nil
        framesSinceLastGood = 0
        captured = nil
        debugKeypoints = [:]
        statusMessage = "Step in front of the camera."
    }

    /// - Parameters:
    ///   - sampleBuffer: Latest camera frame.
    ///   - orientation: How Vision should interpret the pixel buffer's upright
    ///     direction. Callers should derive this from `UIDevice.current.orientation`
    ///     so a portrait-held phone with a landscape-configured camera still
    ///     produces Vision-upright frames.
    func ingest(sampleBuffer: CMSampleBuffer,
                orientation: CGImagePropertyOrientation = .up) {
        guard captured == nil,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        let request = VNDetectHumanBodyPoseRequest()

        do {
            try handler.perform([request])
        } catch {
            return
        }

        let observation = (request.results as? [VNHumanBodyPoseObservation])?.first
        let points = (try? observation?.recognizedPoints(.all)) ?? [:]

        // Publish raw per-frame confidences for the debug overlay — unfiltered
        // by the cache so devs see true frame-by-frame signal.
        if !points.isEmpty {
            var snapshot: [String: Float] = [:]
            for joint in Self.requiredJoints {
                snapshot[shortName(for: joint)] = points[joint]?.confidence ?? 0
            }
            debugKeypoints = snapshot
        } else {
            debugKeypoints = [:]
        }

        // Does this frame meet the threshold on every required joint?
        let frameIsGood: Bool = !points.isEmpty && Self.requiredJoints.allSatisfy {
            (points[$0]?.confidence ?? 0) >= minConfidence
        }

        // Pick the effective reading — this frame if good, else the cache
        // if we're still within the stale-frame budget.
        let effective: GoodReading
        if frameIsGood {
            effective = GoodReading(points: points, pixelBuffer: pixelBuffer)
            lastGood = effective
            framesSinceLastGood = 0
        } else if let cached = lastGood, framesSinceLastGood < maxStaleFrames {
            framesSinceLastGood += 1
            effective = cached
        } else {
            // Either we never had a cache or we've exhausted the grace window.
            let reason = observation == nil
                ? "No person detected. Stand ~6-8 feet from the camera."
                : "Stand facing the camera, whole torso visible."
            breakLock(reason: reason)
            return
        }

        // Advance the lock timer.
        if lockStart == nil { lockStart = .now; statusMessage = "Hold still…" }
        let elapsed = Date.now.timeIntervalSince(lockStart!)
        lockProgress = min(elapsed / requiredDurationSec, 1.0)

        if elapsed >= requiredDurationSec {
            capture(points: effective.points, pixelBuffer: effective.pixelBuffer)
        }
    }

    // MARK: - Private

    private func breakLock(reason: String) {
        lockStart = nil
        lockProgress = 0
        lastGood = nil
        framesSinceLastGood = 0
        statusMessage = reason
    }

    private func shortName(for joint: VNHumanBodyPoseObservation.JointName) -> String {
        switch joint {
        case .leftShoulder:  return "L-shoulder"
        case .rightShoulder: return "R-shoulder"
        case .leftHip:       return "L-hip"
        case .rightHip:      return "R-hip"
        default:             return joint.rawValue.rawValue
        }
    }

    private func capture(
        points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        pixelBuffer: CVPixelBuffer
    ) {
        guard let ls = points[.leftShoulder]?.location,
              let rs = points[.rightShoulder]?.location,
              let lh = points[.leftHip]?.location,
              let rh = points[.rightHip]?.location,
              let nose = points[.nose]?.location,
              let la = points[.leftAnkle]?.location,
              let ra = points[.rightAnkle]?.location
        else {
            // Primary shoulders+hips passed but supporting keypoints are
            // missing. Ask the user to back up so the whole body is visible.
            breakLock(reason: "Couldn't see full body. Step back and try again.")
            return
        }

        let imageWidth  = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imageHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let normalizedBox = AppearanceExtraction.upperBodyBox(
            leftShoulder: ls, rightShoulder: rs, leftHip: lh, rightHip: rh
        )
        let pixelBox = CGRect(
            x: normalizedBox.minX * imageWidth,
            y: (1 - normalizedBox.maxY) * imageHeight,   // Vision Y is bottom-up
            width: normalizedBox.width * imageWidth,
            height: normalizedBox.height * imageHeight
        )

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let (hue, value) = AppearanceExtraction.histograms(from: ciImage, rect: pixelBox)

        let descriptor = AppearanceDescriptor(
            torsoHueHistogram: hue,
            torsoValueHistogram: value,
            heightRatio: AppearanceExtraction.heightRatio(nose: nose, leftAnkle: la, rightAnkle: ra),
            upperBodyAspect: Float(normalizedBox.width / max(normalizedBox.height, 0.001)),
            schemaVersion: HoopTrack.Game.appearanceDescriptorSchemaVersion
        )

        self.captured = descriptor
        self.lockProgress = 1.0
        self.statusMessage = "Captured!"
    }
}
