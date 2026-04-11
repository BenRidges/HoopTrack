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

    // MARK: - Shooting

    static func shootingScore(
        fgPct: Double,
        threePct: Double?,
        ftPct: Double?,
        releaseAngleDeg: Double?,
        releaseAngleStdDev: Double?,
        releaseTimeMs: Double?,
        shotSpeedMph: Double?,
        shotSpeedStdDev: Double?,
        threeAttemptFraction: Double?
    ) -> Double? {
        let R = HoopTrack.SkillRating.self
        var components: [(value: Double, weight: Double)] = []

        components.append((normalize(fgPct, min: 0, max: 100), 0.25))

        if let t = threePct        { components.append((normalize(t, min: 0, max: 100), 0.20)) }
        if let f = ftPct           { components.append((normalize(f, min: 0, max: 100), 0.15)) }

        if let angle = releaseAngleDeg {
            let q: Double
            if angle >= R.releaseAngleOptimalMin && angle <= R.releaseAngleOptimalMax {
                q = 100
            } else if angle < R.releaseAngleFalloffMin || angle > R.releaseAngleFalloffMax {
                q = 0
            } else if angle < R.releaseAngleOptimalMin {
                q = (angle - R.releaseAngleFalloffMin) / (R.releaseAngleOptimalMin - R.releaseAngleFalloffMin) * 100
            } else {
                q = (R.releaseAngleFalloffMax - angle) / (R.releaseAngleFalloffMax - R.releaseAngleOptimalMax) * 100
            }
            components.append((q, 0.15))
        }

        if let ms = releaseTimeMs {
            components.append((normalize(R.releaseTimeSlowMs - ms,
                                         min: 0,
                                         max: R.releaseTimeSlowMs - R.releaseTimeEliteMs), 0.10))
        }

        if let speed = shotSpeedMph {
            let q: Double
            if speed >= R.shotSpeedOptimalMin && speed <= R.shotSpeedOptimalMax {
                q = 100
            } else if speed < R.shotSpeedOptimalMin {
                q = normalize(speed, min: 0, max: R.shotSpeedOptimalMin)
            } else {
                q = normalize(R.shotSpeedOptimalMax * 2 - speed,
                              min: 0, max: R.shotSpeedOptimalMax)
            }
            components.append((q, 0.10))
        }

        if let frac = threeAttemptFraction {
            components.append((normalize(frac * 100, min: 0, max: 60), 0.05))
        }

        guard !components.isEmpty else { return nil }
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        return components.reduce(0.0) { $0 + $1.value * ($1.weight / totalWeight) }
    }

    // MARK: - Ball Handling

    static func ballHandlingScore(
        avgBPS: Double?,
        maxBPS: Double?,
        handBalance: Double?,
        combos: Int,
        totalDribbles: Int
    ) -> Double? {
        guard totalDribbles > 0 else { return nil }
        let R = HoopTrack.SkillRating.self
        var components: [(value: Double, weight: Double)] = []

        if let avg = avgBPS { components.append((normalize(avg, min: R.bpsAvgMin, max: R.bpsAvgMax), 0.30)) }
        if let mx  = maxBPS { components.append((normalize(mx,  min: R.bpsMaxMin, max: R.bpsMaxMax), 0.15)) }

        if let avg = avgBPS, let mx = maxBPS, mx > 0 {
            let ratio = avg / mx
            components.append((normalize(ratio, min: R.bpsSustainedMin, max: R.bpsSustainedMax), 0.15))
        }

        if let balance = handBalance {
            components.append(((1 - abs(balance - 0.5) * 2) * 100, 0.25))
        }

        let comboRate = Double(combos) / Double(totalDribbles)
        components.append((normalize(comboRate, min: 0, max: R.comboRateMax), 0.15))

        guard !components.isEmpty else { return nil }
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        return components.reduce(0.0) { $0 + $1.value * ($1.weight / totalWeight) }
    }

    // MARK: - Athleticism

    static func athleticismScore(
        verticalJumpCm: Double?,
        shuttleRunSec: Double?
    ) -> Double? {
        guard verticalJumpCm != nil || shuttleRunSec != nil else { return nil }
        let R = HoopTrack.SkillRating.self
        var components: [(value: Double, weight: Double)] = []

        if let jump = verticalJumpCm {
            let w = shuttleRunSec == nil ? 1.0 : 0.60
            components.append((normalize(jump, min: R.verticalJumpMinCm, max: R.verticalJumpMaxCm), w))
        }
        if let shuttle = shuttleRunSec {
            let score = normalize(R.laneAgilityWorstSec - shuttle,
                                   min: 0,
                                   max: R.laneAgilityWorstSec - R.laneAgilityBestSec)
            components.append((score, 0.40))
        }

        let totalWeight = components.reduce(0) { $0 + $1.weight }
        return components.reduce(0.0) { $0 + $1.value * ($1.weight / totalWeight) }
    }
}
