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
        .bundled(modelName: HoopTrack.MLModel.bundledModelName,
                 targetLabel: HoopTrack.MLModel.customTargetLabel)
    }
    // ─────────────────────────────────────────────────────────────────────────

    /// Builds the detector for the given configuration.
    /// Returns nil for `.manual` or when a bundled model file is missing —
    /// callers must fall back to manual-only mode. Never crashes.
    static func make(_ configuration: BallDetectorConfiguration) -> BallDetectorProtocol? {
        switch configuration {
        case .stub:
            return BallDetectorStub()

        case .bundled(let modelName, let targetLabel):
            // Xcode compiles the .mlpackage source into .mlmodelc at build
            // time and ships only the compiled directory inside the .app.
            guard let url = Bundle.main.url(forResource: modelName,
                                             withExtension: "mlmodelc") else {
                return nil   // model not bundled — caller falls back to manual
            }
            return CoreMLBallDetector(modelURL: url, targetLabel: targetLabel)

        case .manual:
            return nil
        }
    }
}
