// HoopTrack/Models/DribbleLiveMetrics.swift
// Value-type DTO carrying live dribble state from DribblePipeline → DribbleSessionViewModel.

import CoreGraphics

struct DribbleLiveMetrics {
    var totalDribbles: Int        = 0
    var leftHandDribbles: Int     = 0
    var rightHandDribbles: Int    = 0
    var currentBPS: Double        = 0   // dribbles per second (rolling 3-sec window)
    var maxBPS: Double            = 0
    var combosDetected: Int       = 0
    var lastActiveHand: DribbleCalculator.HandSide? = nil
    /// Normalised image position of left wrist (nil if not visible).
    var leftWristPosition: CGPoint?  = nil
    /// Normalised image position of right wrist (nil if not visible).
    var rightWristPosition: CGPoint? = nil
}
