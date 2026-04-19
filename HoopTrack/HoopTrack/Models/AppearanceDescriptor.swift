// AppearanceDescriptor.swift
// A small serialisable profile captured during Game Mode registration.
// Session-scoped — never written outside the GamePlayer that owns it,
// never uploaded. See docs/superpowers/specs/2026-04-19-game-foundation-design.md §3.

import Foundation

struct AppearanceDescriptor: Codable, Sendable, Equatable {
    /// 8-bin hue histogram of upper-body pixels, normalised so bins sum to 1.0.
    let torsoHueHistogram: [Float]

    /// 4-bin value/brightness histogram of the same region, also normalised.
    let torsoValueHistogram: [Float]

    /// Body height as a fraction of frame height (0..1).
    let heightRatio: Float

    /// Upper-body bounding-box aspect ratio (width / height).
    let upperBodyAspect: Float

    /// Schema version for future descriptor upgrades.
    let schemaVersion: Int

    /// True when the descriptor matches the expected schema — used in tests
    /// and defensively by the matcher in SP2.
    var isWellFormed: Bool {
        guard torsoHueHistogram.count == HoopTrack.Game.histogramHueBins,
              torsoValueHistogram.count == HoopTrack.Game.histogramValueBins,
              heightRatio >= 0, heightRatio <= 1,
              upperBodyAspect > 0
        else { return false }
        let hueSum = torsoHueHistogram.reduce(0, +)
        let valueSum = torsoValueHistogram.reduce(0, +)
        let tolerance: Float = 0.02
        return abs(hueSum - 1.0) < tolerance && abs(valueSum - 1.0) < tolerance
    }
}
