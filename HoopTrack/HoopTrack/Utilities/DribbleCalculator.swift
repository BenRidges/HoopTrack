// HoopTrack/Utilities/DribbleCalculator.swift
// Pure dribble math. No side effects. All functions are static.

import Foundation

enum DribbleCalculator {

    enum HandSide {
        case left, right
    }

    // MARK: - Dribbles Per Second

    /// Returns dribbles per second, or nil if durationSec is zero.
    static func dribblesPerSecond(count: Int, durationSec: Double) -> Double? {
        guard durationSec > 0 else { return nil }
        return Double(count) / durationSec
    }

    // MARK: - Hand Balance

    /// Returns fraction of dribbles performed with the left hand (0.0 = all right, 1.0 = all left).
    /// Returns nil if both counts are zero.
    static func handBalance(leftCount: Int, rightCount: Int) -> Double? {
        let total = leftCount + rightCount
        guard total > 0 else { return nil }
        return Double(leftCount) / Double(total)
    }

    // MARK: - Combo Count

    /// Counts the number of hand switches (each switch = one combo rep).
    static func comboCount(handHistory: [HandSide]) -> Int {
        guard handHistory.count >= 2 else { return 0 }
        var count = 0
        for i in 1 ..< handHistory.count {
            if handHistory[i] != handHistory[i - 1] { count += 1 }
        }
        return count
    }
}
