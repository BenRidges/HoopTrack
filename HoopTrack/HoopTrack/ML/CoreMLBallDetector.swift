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

        // Path 1 — model has built-in NMS + object-detection metadata
        // (Ultralytics export with `nms=True`). Vision returns VNRecognized-
        // ObjectObservation and we filter by label + pick largest.
        if let results = request.results as? [VNRecognizedObjectObservation], !results.isEmpty {
            let label = targetLabel.lowercased()
            if let best = results
                .filter({ obs in
                    obs.confidence >= confidenceThreshold &&
                    obs.labels.first?.identifier.lowercased().contains(label) == true
                })
                .max(by: { $0.boundingBox.area < $1.boundingBox.area }) {
                return BallDetection(
                    boundingBox: best.boundingBox,
                    confidence: best.confidence,
                    frameTimestamp: CMSampleBufferGetPresentationTimeStamp(buffer)
                )
            }
            return nil
        }

        // Path 2 — model exports a raw YOLO tensor (Ultralytics default:
        // `nms=False end2end=False`). Shape [1, 4+C, 8400] where 4 bbox
        // values come first, followed by per-class confidences. Decode
        // the highest-scoring ball anchor directly.
        if let feature = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue,
           let tensor = feature.multiArrayValue {
            return decodeYOLO(tensor, buffer: buffer)
        }

        return nil
    }

    /// Single-best-box decoder for Ultralytics YOLO raw CoreML output.
    /// Skips full NMS (we just want the top-scoring detection for the debug
    /// overlay + state machine). If multiple basketballs are ever needed,
    /// swap this for proper IoU-based NMS.
    private func decodeYOLO(_ tensor: MLMultiArray, buffer: CMSampleBuffer) -> BallDetection? {
        // Expect shape [1, 4 + numClasses, numAnchors] — YOLOv8 CoreML export.
        guard tensor.shape.count == 3,
              tensor.shape[0].intValue == 1 else { return nil }

        let features  = tensor.shape[1].intValue   // 4 bbox + numClasses
        let anchors   = tensor.shape[2].intValue   // e.g. 8400 for 640×640
        let numClasses = features - 4
        guard numClasses >= 1 else { return nil }

        // "ball" is class 0 in this model's class list (ball, basket, person).
        // Assume the first class matches targetLabel; callers configure this
        // to "ball" via Constants.customTargetLabel.
        let targetClass = 0

        let ptr = tensor.dataPointer.assumingMemoryBound(to: Float.self)

        // C-order row-major: index(feature, anchor) = feature * anchors + anchor
        func value(_ feature: Int, _ anchor: Int) -> Float {
            ptr[feature * anchors + anchor]
        }

        var bestAnchor = -1
        var bestScore  = confidenceThreshold
        for anchor in 0..<anchors {
            let score = value(4 + targetClass, anchor)
            if score > bestScore {
                bestScore  = score
                bestAnchor = anchor
            }
        }
        guard bestAnchor >= 0 else { return nil }

        // Bounding box in model input pixel space (640 × 640 for this model).
        let cx = value(0, bestAnchor)
        let cy = value(1, bestAnchor)
        let w  = value(2, bestAnchor)
        let h  = value(3, bestAnchor)

        // Normalise to 0–1. Note: Vision's `.scaleFit` crop option lets the
        // model see a letterboxed image when the input aspect ratio differs
        // from 1:1 — the returned coords live in the 640-square, not the
        // original frame. The overlay will therefore be geometrically close
        // but not pixel-perfect. Re-export with `nms=True` to get proper
        // Vision-normalised bounding boxes.
        let modelSize: Float = 640
        let normX = (cx - w / 2) / modelSize
        let normW = w / modelSize
        let normH = h / modelSize
        // Vision coords: origin bottom-left, increasing upward.
        let normYFromTop = (cy - h / 2) / modelSize
        let normY = 1.0 - normYFromTop - normH

        return BallDetection(
            boundingBox: CGRect(x: CGFloat(normX), y: CGFloat(normY),
                                 width: CGFloat(normW), height: CGFloat(normH)),
            confidence: bestScore,
            frameTimestamp: CMSampleBufferGetPresentationTimeStamp(buffer)
        )
    }
}

nonisolated private extension CGRect {
    var area: CGFloat { width * height }
}
