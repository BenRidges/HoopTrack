// HoopTrack/Models/ShotScienceMetrics.swift
// Value type carrying per-shot biomechanics from CVPipeline to DataService.
// All fields are optional — nil means the measurement wasn't available.

import Foundation

nonisolated struct ShotScienceMetrics: Sendable {
    /// Launch angle above horizontal (degrees), from flight time. Optimal 43–57°.
    var releaseAngleDeg: Double?
    /// Not measured by the current pipeline; kept for older data and sync.
    var releaseTimeMs: Double?
    /// Not measured by the current pipeline; kept for older data and sync.
    var verticalJumpCm: Double?
    /// Not measured by the current pipeline; kept for older data and sync.
    var legAngleDeg: Double?
    /// Launch speed (mph), from flight time and distance.
    var shotSpeedMph: Double?
}
