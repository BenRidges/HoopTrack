// HoopTrack/Utilities/ShotScienceCalculator.swift
// Pure biomechanics math. Vision-dependent wrappers call the geometry functions.
// No side effects. All functions are static.

import CoreGraphics
import AVFoundation
import Vision

nonisolated enum ShotScienceCalculator {

    // MARK: - Release Angle

    /// Ball launch angle from horizontal (degrees).
    /// Uses the midpoints of the first two detections in the trajectory.
    /// Vision Y origin is bottom-left (increasing upward).
    /// Returns nil if the ball is not ascending (dy ≤ 0).
    static func releaseAngle(trajectory: [BallDetection]) -> Double? {
        guard trajectory.count >= 2 else { return nil }
        let p1 = trajectory[0].boundingBox
        let p2 = trajectory[1].boundingBox
        let dx = Double(p2.midX - p1.midX)
        let dy = Double(p2.midY - p1.midY)
        guard dy > 0 else { return nil }   // ball must be ascending at release
        let angleRad = atan2(dy, abs(dx))
        return angleRad * (180.0 / Double.pi)
    }

    // MARK: - Release Time

    static func releaseTime(trajectory: [BallDetection]) -> Double? {
        guard trajectory.count >= 2 else { return nil }
        let start  = CMTimeGetSeconds(trajectory.first!.frameTimestamp)
        let end    = CMTimeGetSeconds(trajectory.last!.frameTimestamp)
        let elapsedSec = end - start
        guard elapsedSec > 0 else { return nil }
        return elapsedSec * 1000.0
    }

    // MARK: - Shot Speed

    static func shotSpeed(trajectory: [BallDetection], hoopRectWidth: CGFloat) -> Double? {
        guard trajectory.count >= 2, hoopRectWidth > 0 else { return nil }
        let p1 = trajectory[0].boundingBox
        let p2 = trajectory[1].boundingBox
        let t1 = CMTimeGetSeconds(trajectory[0].frameTimestamp)
        let t2 = CMTimeGetSeconds(trajectory[1].frameTimestamp)
        let elapsedSec = t2 - t1
        guard elapsedSec > 0 else { return nil }

        let dx = Double(p2.midX - p1.midX)
        let dy = Double(p2.midY - p1.midY)
        let distNorm       = sqrt(dx * dx + dy * dy)
        let scaleCmPerUnit = 45.72 / Double(hoopRectWidth)
        let distCm         = distNorm * scaleCmPerUnit
        let speedCmps      = distCm / elapsedSec
        return speedCmps * 0.0224
    }

    // MARK: - Consistency Score

    static func consistencyScore(releaseAngles: [Double]) -> Double? {
        guard releaseAngles.count >= 2 else { return nil }
        let mean     = releaseAngles.reduce(0, +) / Double(releaseAngles.count)
        let variance = releaseAngles.map { pow($0 - mean, 2) }.reduce(0, +)
                     / Double(releaseAngles.count)
        return sqrt(variance)
    }

    // MARK: - Leg Angle (pure geometry)

    static func legAngleGeometry(hip: CGPoint, knee: CGPoint, ankle: CGPoint) -> Double? {
        let v1 = CGVector(dx: hip.x   - knee.x, dy: hip.y   - knee.y)
        let v2 = CGVector(dx: ankle.x - knee.x, dy: ankle.y - knee.y)
        let dot  = v1.dx * v2.dx + v1.dy * v2.dy
        let mag1 = sqrt(v1.dx * v1.dx + v1.dy * v1.dy)
        let mag2 = sqrt(v2.dx * v2.dx + v2.dy * v2.dy)
        guard mag1 > 0, mag2 > 0 else { return nil }
        let cosAngle = max(-1.0, min(1.0, dot / (mag1 * mag2)))
        return Double(acos(Double(cosAngle))) * (180.0 / Double.pi)
    }

    static func legAngle(from observation: VNHumanBodyPoseObservation) -> Double? {
        guard let hip   = try? observation.recognizedPoint(.leftHip),
              let knee  = try? observation.recognizedPoint(.leftKnee),
              let ankle = try? observation.recognizedPoint(.leftAnkle),
              hip.confidence   > 0.3,
              knee.confidence  > 0.3,
              ankle.confidence > 0.3 else { return nil }
        return legAngleGeometry(hip:   hip.location,
                                knee:  knee.location,
                                ankle: ankle.location)
    }

    // MARK: - Vertical Jump (pure geometry)

    static func verticalJumpGeometry(hipY: Double, ankleY: Double, shoulderY: Double) -> Double? {
        let bodyHeight = shoulderY - ankleY
        guard bodyHeight > 0.1 else { return nil }

        let hipHeightFrac    = (hipY - ankleY) / bodyHeight
        let standingBaseline = 0.55
        let excessFrac       = hipHeightFrac - standingBaseline
        let estimatedJumpCm  = excessFrac * 180.0
        return estimatedJumpCm > 3.0 ? estimatedJumpCm : nil
    }

    static func estimatedVerticalJump(from observation: VNHumanBodyPoseObservation) -> Double? {
        guard let hip      = try? observation.recognizedPoint(.leftHip),
              let ankle    = try? observation.recognizedPoint(.leftAnkle),
              let shoulder = try? observation.recognizedPoint(.leftShoulder),
              hip.confidence      > 0.3,
              ankle.confidence    > 0.3,
              shoulder.confidence > 0.3 else { return nil }
        return verticalJumpGeometry(hipY:      Double(hip.location.y),
                                    ankleY:    Double(ankle.location.y),
                                    shoulderY: Double(shoulder.location.y))
    }

    // MARK: - Convenience bundle

    static func compute(trajectory: [BallDetection],
                        poseObservation: VNHumanBodyPoseObservation?,
                        hoopRectWidth: CGFloat) -> ShotScienceMetrics {
        ShotScienceMetrics(
            releaseAngleDeg: releaseAngle(trajectory: trajectory),
            releaseTimeMs:   releaseTime(trajectory: trajectory),
            verticalJumpCm:  poseObservation.flatMap { estimatedVerticalJump(from: $0) },
            legAngleDeg:     poseObservation.flatMap { legAngle(from: $0) },
            shotSpeedMph:    shotSpeed(trajectory: trajectory, hoopRectWidth: hoopRectWidth)
        )
    }
}
