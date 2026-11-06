// DribbleCalculator.swift
// Pure dribble maths. No side effects.

import Foundation

nonisolated enum DribbleCalculator {

    enum HandSide: Sendable {
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

/// Counts dribbles from one wrist's vertical position. A dribble is the hand
/// pushing down and coming back up; we count it at the bottom turn, but only
/// when both the push and the recovery cover a real distance relative to
/// the player's torso — so tracking jitter and small hand wobbles don't count.
nonisolated struct WristBounceDetector: Sendable {

    /// Minimum push / recovery, as a fraction of torso length.
    var threshold: Double = 0.12

    private enum Direction: Sendable { case unknown, down, up }
    private var direction: Direction = .unknown
    private var high: Double = 0
    private var low: Double = 0

    init(threshold: Double = 0.12) {
        self.threshold = threshold
    }

    /// - Parameters:
    ///   - y: wrist height, normalised with y increasing upward.
    ///   - torso: torso length in the same units (neck → hip centre).
    /// - Returns: true when a dribble completes on this sample.
    mutating func update(y: Double, torso: Double) -> Bool {
        let step = threshold * max(torso, 0.05)
        switch direction {
        case .unknown:
            high = y; low = y
            direction = .down
            return false
        case .down:
            if y < low { low = y }
            if y > low + step {
                let pushed = high - low >= step
                direction = .up
                high = y
                return pushed
            }
            return false
        case .up:
            if y > high { high = y }
            if y < high - step {
                direction = .down
                low = y
            }
            return false
        }
    }

    mutating func reset() {
        direction = .unknown
    }
}
