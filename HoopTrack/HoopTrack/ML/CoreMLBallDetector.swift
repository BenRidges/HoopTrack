// HoopTrack/ML/CoreMLBallDetector.swift
// Wraps any Core ML object-detection model via VNCoreMLRequest.
// Filters detections by a configurable target label so COCO ("sports ball")
// and custom models ("basketball") both work without code changes.

@preconcurrency import Vision
import CoreML
import AVFoundation
import CoreGraphics

nonisolated final class CoreMLBallDetector: BallDetectorProtocol {

    nonisolated(unsafe) private let request: VNCoreMLRequest
    private let targetLabel: String
    private let confidenceThreshold: Float

    /// Failable init — returns nil if the model file cannot be loaded.
    /// Caller should fall back to manual-only mode when this returns nil.
    init?(modelURL: URL,
          targetLabel: String = "basketball",
          confidenceThreshold: Float = HoopTrack.Camera.ballDetectionConfidenceThreshold) {
        guard let mlModel = try? MLModel(contentsOf: modelURL,
                                         configuration: MLModelConfiguration()),
              let vnModel = try? VNCoreMLModel(for: mlModel) else { return nil }

        self.targetLabel         = targetLabel
        self.confidenceThreshold = confidenceThreshold

        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFit
        self.request = req
    }

    func detect(buffer: CMSampleBuffer) -> BallDetection? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        try? handler.perform([request])

        guard let results = request.results as? [VNRecognizedObjectObservation] else { return nil }

        let label = targetLabel.lowercased()
        guard let best = results
            .filter({ obs in
                obs.confidence >= confidenceThreshold &&
                obs.labels.first?.identifier.lowercased().contains(label) == true
            })
            .max(by: { $0.boundingBox.area < $1.boundingBox.area })
        else { return nil }

        return BallDetection(
            boundingBox: best.boundingBox,
            confidence: best.confidence,
            frameTimestamp: CMSampleBufferGetPresentationTimeStamp(buffer)
        )
    }
}

nonisolated private extension CGRect {
    var area: CGFloat { width * height }
}
