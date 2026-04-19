// AppearanceCaptureService.swift
// Ingests CMSampleBuffers, runs Vision body-pose detection, and emits an
// AppearanceDescriptor once a high-confidence lock has held for
// HoopTrack.Game.registrationLockDurationSec seconds.

import Foundation
import Combine
import Vision
import CoreImage
import AVFoundation

@MainActor
final class AppearanceCaptureService: ObservableObject {

    @Published private(set) var lockProgress: Double = 0   // 0..1
    @Published private(set) var captured: AppearanceDescriptor?
    @Published private(set) var statusMessage: String = "Step in front of the camera."

    private var lockStart: Date?
    private let minConfidence: Float = HoopTrack.Game.registrationMinBodyConfidence
    private let requiredDurationSec: Double = HoopTrack.Game.registrationLockDurationSec

    func reset() {
        lockStart = nil
        lockProgress = 0
        captured = nil
        statusMessage = "Step in front of the camera."
    }

    func ingest(sampleBuffer: CMSampleBuffer) {
        guard captured == nil,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let request = VNDetectHumanBodyPoseRequest()

        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observation = (request.results as? [VNHumanBodyPoseObservation])?.first,
              let points = try? observation.recognizedPoints(.all) else {
            breakLock(reason: "No person detected. Stand ~6-8 feet from the camera.")
            return
        }

        // Require high-confidence shoulder + hip keypoints.
        let required: [VNHumanBodyPoseObservation.JointName] =
            [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
        for joint in required {
            guard let p = points[joint], p.confidence >= minConfidence else {
                breakLock(reason: "Stand facing the camera, whole torso visible.")
                return
            }
        }

        if lockStart == nil { lockStart = .now; statusMessage = "Hold still…" }
        let elapsed = Date.now.timeIntervalSince(lockStart!)
        lockProgress = min(elapsed / requiredDurationSec, 1.0)

        if elapsed >= requiredDurationSec {
            capture(points: points, pixelBuffer: pixelBuffer)
        }
    }

    // MARK: - Private

    private func breakLock(reason: String) {
        lockStart = nil
        lockProgress = 0
        statusMessage = reason
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
