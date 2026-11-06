// HoopTrack/ML/CoreMLBallDetector.swift
// Wraps the bundled Core ML object detector via VNCoreMLRequest and returns
// every ball candidate plus the best hoop for each frame.
//
// Class matching is by label substring against HoopTrack.MLModel.ballLabels /
// hoopLabels. The shipped model's classes are ball / basket / person; a
// previous change looked for "rim" only, which meant the hoop was never
// found and automatic tracking could never start.

@preconcurrency import Vision
import CoreML
import AVFoundation
import CoreGraphics

nonisolated final class CoreMLBallDetector: BallDetectorProtocol {

    nonisolated(unsafe) private let request: VNCoreMLRequest
    private let ballLabels: [String]
    private let hoopLabels: [String]

    /// Failable init — returns nil if the model file cannot be loaded.
    /// Caller falls back to manual-only mode when this returns nil.
    init?(modelURL: URL,
          ballLabels: [String] = HoopTrack.MLModel.ballLabels,
          hoopLabels: [String] = HoopTrack.MLModel.hoopLabels) {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let mlModel = try? MLModel(contentsOf: modelURL, configuration: configuration),
              let vnModel = try? VNCoreMLModel(for: mlModel) else { return nil }

        self.ballLabels = ballLabels.map { $0.lowercased() }
        self.hoopLabels = hoopLabels.map { $0.lowercased() }

        let req = VNCoreMLRequest(model: vnModel)
        // YOLO was trained on letterboxed squares; scaleFit matches that and
        // Vision undoes the letterbox in the boxes it returns.
        req.imageCropAndScaleOption = .scaleFit
        self.request = req
    }

    func detectScene(buffer: CMSampleBuffer, region: CGRect?) -> SceneDetection? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)

        // Vision returns boxes relative to the region of interest; they're
        // mapped back to the full frame below.
        let roi = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        request.regionOfInterest = roi

        // Frames arrive already rotated by the capture connection, so `.up`.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return SceneDetection(balls: [], baskets: [], frameTimestamp: timestamp)
        }

        let results = request.results as? [VNRecognizedObjectObservation] ?? []
        var balls: [BallDetection] = []
        var hoops: [BallDetection] = []

        for observation in results {
            guard let label = observation.labels.first?.identifier.lowercased() else { continue }
            let detection = BallDetection(boundingBox: DetectionRegion.toFullFrame(observation.boundingBox, from: roi),
                                          confidence: observation.confidence,
                                          frameTimestamp: timestamp)
            if isHoop(label) {
                guard observation.confidence >= HoopTrack.CV.hoopConfidence else { continue }
                hoops.append(detection)
            } else if ballLabels.contains(where: { label.contains($0) }) {
                guard observation.confidence >= HoopTrack.CV.ballConfidence else { continue }
                balls.append(detection)
            }
        }

        balls.sort { $0.confidence > $1.confidence }
        hoops.sort { $0.confidence > $1.confidence }
        return SceneDetection(balls: Array(balls.prefix(4)), baskets: Array(hoops.prefix(3)),
                              frameTimestamp: timestamp)
    }

    /// Whole-word match so a "basketball" class never counts as a hoop just
    /// because it contains "basket".
    private func isHoop(_ label: String) -> Bool {
        let words = label.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return hoopLabels.contains { words.contains($0) }
    }
}
