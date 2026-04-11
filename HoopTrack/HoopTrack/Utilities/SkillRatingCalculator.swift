// SkillRatingCalculator.swift
// Pure static functions — no SwiftData, no side effects.
// SkillRatingService extracts primitives from @Model types before calling here.

import Foundation

enum SkillRatingCalculator {

    // MARK: - Normalize

    /// Clamps `value` to [min, max] then scales linearly to 0–100.
    static func normalize(_ value: Double, min: Double, max: Double) -> Double {
        guard max > min else { return 0 }
        return Swift.max(0, Swift.min(100, (value - min) / (max - min) * 100))
    }
}
