// HoopTrack/Models/ShotScienceMetrics.swift
// Value-type DTO that carries biomechanics data from CVPipeline
// through LiveSessionViewModel to DataService.
// All fields are optional — nil means the measurement was unavailable.

import Foundation

struct ShotScienceMetrics: Sendable {
    /// Ball launch angle from horizontal at release (degrees). Optimal 43–57°.
    var releaseAngleDeg: Double?
    /// Time from first ball detection to release peak (milliseconds).
    var releaseTimeMs: Double?
    /// Estimated vertical jump height at release (centimetres). Rough approximation.
    var verticalJumpCm: Double?
    /// Knee-joint angle at jump initiation (degrees). Derived from Vision body pose.
    var legAngleDeg: Double?
    /// Estimated ball velocity post-release (MPH). Derived from trajectory + hoop-size scale.
    var shotSpeedMph: Double?
}
