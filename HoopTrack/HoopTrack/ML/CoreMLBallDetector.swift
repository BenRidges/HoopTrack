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
    /// Skips full NMS — we only need the top-scoring detection for the debug
    /// overlay and the single-ball state machine. Properly unmaps the
    /// letterbox that Vision's `.scaleFit` applies when the source frame
    /// aspect ratio differs from the model's 1:1 input.
    private func decodeYOLO(_ tensor: MLMultiArray, buffer: CMSampleBuffer) -> BallDetection? {
        // Expect shape [1, 4 + numClasses, numAnchors] — YOLOv8 CoreML export.
        guard tensor.shape.count == 3,
              tensor.shape[0].intValue == 1 else { return nil }

        let features  = tensor.shape[1].intValue   // 4 bbox + numClasses
        let anchors   = tensor.shape[2].intValue   // e.g. 8400 for 640×640
        let numClasses = features - 4
        guard numClasses >= 1 else { return nil }

        // Class indices from the model metadata: 0=ball, 1=basket, 2=person.
        let targetClass = 0

        // Source frame dimensions — needed to unmap the Vision letterbox.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let frameWidth  = Float(CVPixelBufferGetWidth(pixelBuffer))
        let frameHeight = Float(CVPixelBufferGetHeight(pixelBuffer))
        guard frameWidth > 0, frameHeight > 0 else { return nil }

        // Letterbox math for Vision `.scaleFit` into a 640×640 model input.
        // scale = min ratio so the whole image fits; padding fills the rest.
        let modelSize: Float = 640
        let scale  = min(modelSize / frameWidth, modelSize / frameHeight)
        let contentWidth  = frameWidth  * scale
        let contentHeight = frameHeight * scale
        let padX = (modelSize - contentWidth)  / 2
        let padY = (modelSize - contentHeight) / 2

        // Raw anchors confidence is un-suppressed; use a more sensitive
        // threshold than the NMS path. 0.25 is Ultralytics' default conf.
        let rawThreshold: Float = 0.25

        let ptr = tensor.dataPointer.assumingMemoryBound(to: Float.self)
        // C-order row-major: index(feature, anchor) = feature * anchors + anchor
        func value(_ feature: Int, _ anchor: Int) -> Float {
            ptr[feature * anchors + anchor]
        }

        var bestAnchor = -1
        var bestScore  = rawThreshold
        for anchor in 0..<anchors {
            let cy = value(1, anchor)
            // Reject detections whose centre falls inside the letterbox bars
            // — they can't correspond to real content and are pure noise.
            guard cy >= padY, cy <= modelSize - padY else { continue }
            let score = value(4 + targetClass, anchor)
            if score > bestScore {
                bestScore  = score
                bestAnchor = anchor
            }
        }
        guard bestAnchor >= 0 else { return nil }

        // Bounding box in model input pixel space (0..640 on each axis).
        let cx = value(0, bestAnchor)
        let cy = value(1, bestAnchor)
        let w  = value(2, bestAnchor)
        let h  = value(3, bestAnchor)

        // Remove letterbox offsets, then normalise by the actual content
        // extent so the returned rect covers [0,1] of the original frame.
        let xInContent = cx - padX
        let yInContent = cy - padY
        let normX = (xInContent - w / 2) / contentWidth
        let normW = w / contentWidth
        let normH = h / contentHeight
        // Vision convention: origin bottom-left, increasing upward.
        let normYFromTop = (yInContent - h / 2) / contentHeight
        let normY = 1.0 - normYFromTop - normH

        // Clamp in case the model emits a box slightly outside the frame.
        let clamp: (Float) -> CGFloat = { CGFloat(max(0, min(1, $0))) }

        return BallDetection(
            boundingBox: CGRect(x: clamp(normX),       y: clamp(normY),
                                 width: clamp(normW),  height: clamp(normH)),
            confidence: bestScore,
            frameTimestamp: CMSampleBufferGetPresentationTimeStamp(buffer)
        )
    }
}

nonisolated private extension CGRect {
    var area: CGFloat { width * height }
}
