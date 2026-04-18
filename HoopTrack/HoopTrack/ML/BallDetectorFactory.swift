// HoopTrack/ML/BallDetectorFactory.swift
// Single place to configure which ball detector is active.
// Change `BallDetectorFactory.active` to switch models — no other code changes needed.

import Foundation

// MARK: - Configuration

enum BallDetectorConfiguration {
    /// DEBUG-only synthetic shot arc — no camera or model needed.
    case stub
    /// Core ML .mlpackage bundled in the app target.
    /// - modelName: bundle resource name without extension
    /// - targetLabel: detection class to filter for (e.g. "basketball", "sports ball")
    case bundled(modelName: String, targetLabel: String)
    /// No CV detection — manual Make/Miss buttons only. No crash, no model required.
    case manual
}

// MARK: - Factory

enum BallDetectorFactory {

    // ─────────────────────────────────────────────────────────────────────────
    // SWAP MODELS HERE — change `active` to switch detectors.
    // Examples:
    //   .stub                                                    → debug arc
    //   .bundled(modelName: "BallDetector", targetLabel: "basketball")   → custom model
    //   .bundled(modelName: "BallDetector", targetLabel: "sports ball")  → COCO model
    //   .manual                                                  → buttons only
    // ─────────────────────────────────────────────────────────────────────────
    static var active: BallDetectorConfiguration {
        // CoreML inference on the iOS simulator uses a CPU-only path that
        // crashes on some model ops. Use the synthetic stub in the simulator
        // and the real bundled model on device.
        #if targetEnvironment(simulator)
        return .stub
        #else
        return .bundled(modelName: HoopTrack.MLModel.bundledModelName,
                        targetLabel: HoopTrack.MLModel.customTargetLabel)
        #endif
    }
    // ─────────────────────────────────────────────────────────────────────────

    /// Builds the detector for the given configuration.
    /// Returns nil for `.manual` or when a bundled model file is missing —
    /// callers must fall back to manual-only mode. Never crashes.
    static func make(_ configuration: BallDetectorConfiguration) -> BallDetectorProtocol? {
        switch configuration {
        case .stub:
            #if DEBUG
            return BallDetectorStub()
            #else
            return nil
            #endif

        case .bundled(let modelName, let targetLabel):
            guard let url = Bundle.main.url(forResource: modelName,
                                             withExtension: "mlpackage") else {
                return nil   // model not bundled — caller falls back to manual
            }
            return CoreMLBallDetector(modelURL: url, targetLabel: targetLabel)

        case .manual:
            return nil
        }
    }
}
