// HoopTrack/Models/DribbleLiveMetrics.swift
// Live dribble state from DribblePipeline → DribbleSessionViewModel.

import CoreGraphics

nonisolated struct DribbleLiveMetrics: Sendable {
    var totalDribbles: Int        = 0
    var leftHandDribbles: Int     = 0
    var rightHandDribbles: Int    = 0
    var currentBPS: Double        = 0   // dribbles per second (rolling window)
    var maxBPS: Double            = 0
    var combosDetected: Int       = 0
    var lastActiveHand: DribbleCalculator.HandSide? = nil
    /// True while a body is in frame.
    var isPlayerVisible: Bool     = false
}
