// HoopTrack/ML/BallDetectorFactory.swift
// Single place to configure which ball detector is active.
// Change `BallDetectorFactory.active` to switch models — no other code changes needed.

import Foundation

// MARK: - Configuration

nonisolated enum BallDetectorConfiguration {
    /// DEBUG-only synthetic shot arc — no camera or model needed.
    case stub
    /// Core ML model bundled in the app target (resource name without extension).
    case bundled(modelName: String)
    /// No CV detection — manual Make/Miss buttons only. No crash, no model required.
    case manual
}

// MARK: - Factory

nonisolated enum BallDetectorFactory {

    // ─────────────────────────────────────────────────────────────────────────
    // SWAP MODELS HERE — change `active` to switch detectors.
    // Examples:
    //   .stub                                  → debug arc
    //   .bundled(modelName: "BallDetector")    → shipped model
    //   .manual                                → buttons only
    // Class labels are matched in CoreMLBallDetector via HoopTrack.MLModel.
    // ─────────────────────────────────────────────────────────────────────────
    static var active: BallDetectorConfiguration {
        .bundled(modelName: HoopTrack.MLModel.bundledModelName)
    }
    // ─────────────────────────────────────────────────────────────────────────

    /// Builds the detector for the given configuration.
    /// Returns nil for `.manual` or when a bundled model file is missing —
    /// callers must fall back to manual-only mode. Never crashes.
    static func make(_ configuration: BallDetectorConfiguration) -> BallDetectorProtocol? {
        switch configuration {
        case .stub:
            return BallDetectorStub()

        case .bundled(let modelName):
            // Xcode compiles the .mlpackage source into .mlmodelc at build
            // time and ships only the compiled directory inside the .app.
            guard let url = Bundle.main.url(forResource: modelName,
                                             withExtension: "mlmodelc") else {
                return nil   // model not bundled — caller falls back to manual
            }
            return CoreMLBallDetector(modelURL: url)

        case .manual:
            return nil
        }
    }
}
