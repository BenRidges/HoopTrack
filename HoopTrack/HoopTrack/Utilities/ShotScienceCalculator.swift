// HoopTrack/Utilities/ShotScienceCalculator.swift
// Session-level shot science aggregates. Per-shot launch angle and speed
// come from ShotPhysics (flight-time based) in ShotGeometry.swift.
//
// The old per-shot helpers (two-point release angle, single-frame vertical
// jump and knee angle) were removed: from a camera behind the shooter the
// image-space angle is foreshortened to ~90° for every shot, and a single
// pose frame can't tell a jump from a crouch.

import Foundation

nonisolated enum ShotScienceCalculator {

    /// Population standard deviation of launch angles — lower is more
    /// consistent. Nil with fewer than two shots.
    static func consistencyScore(releaseAngles: [Double]) -> Double? {
        guard releaseAngles.count >= 2 else { return nil }
        let mean     = releaseAngles.reduce(0, +) / Double(releaseAngles.count)
        let variance = releaseAngles.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
                     / Double(releaseAngles.count)
        return variance.squareRoot()
    }
}
