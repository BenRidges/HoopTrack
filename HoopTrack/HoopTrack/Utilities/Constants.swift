// Constants.swift
// App-wide constants. All magic numbers and configuration live here.

import Foundation
import CoreGraphics

enum HoopTrack {

    // MARK: - App Info
    static let appName    = "HoopTrack"
    static let bundleID   = "com.hooptrack.app"
    static let minIOSVersion = 16.0

    // MARK: - Camera / CV
    enum Camera {
        static let targetFPS: Double        = 60
        static let sessionPreset            = "AVCaptureSessionPreset1280x720"
        static let maxProcessingLatencyMs   = 20.0  // < 20ms per frame target
        static let shotDetectionLatencyMs   = 500.0 // < 0.5s from release to confirm
        static let ballDetectionConfidenceThreshold: Float = 0.45
    }

    // MARK: - ML Model
    enum MLModel {
        /// Resource name of the bundled .mlpackage (without extension).
        static let bundledModelName  = "BallDetector"
        /// Target label for COCO-trained models (YOLOv8n, YOLOv5n, etc.)
        static let cocoTargetLabel   = "sports ball"
        /// Target label for basketball-specific models (Roboflow, custom).
        static let customTargetLabel = "basketball"
    }

    // MARK: - Court Geometry (normalised 0–1 half-court space)
    // These drive zone classification in the CV pipeline (Phase 2).
    enum CourtGeometry {
        // Paint box: centered horizontally, extends from baseline
        static let paintWidthFraction:  Double = 0.32
        static let paintHeightFraction: Double = 0.38

        // Free throw line Y (from baseline = 0)
        static let freeThrowLineFraction: Double = 0.38

        // Three-point arc radius as fraction of half-court width
        static let threePointArcRadiusFraction: Double = 0.47

        // Corner 3 depth from baseline
        static let cornerThreeDepthFraction: Double = 0.28
    }

    // MARK: - Shot Science (Phase 3 thresholds)
    enum ShotScience {
        static let optimalReleaseAngleMin: Double = 43  // degrees
        static let optimalReleaseAngleMax: Double = 57
        static let consistencyThreshold:   Double = 3.0 // degrees variance — "good" below this
    }

    // MARK: - Dribble (Phase 4 thresholds)
    enum Dribble {
        /// Minimum wrist Y displacement (normalised 0–1) to count as a dribble bounce.
        static let minWristDisplacementFrac: Double = 0.03
        /// Frames a wrist velocity must sustain a direction change to avoid noise triggers.
        static let velocityConfirmFrames: Int = 2
        /// Optimal dribbles-per-second range for ball-handling drills.
        static let optimalBPSMin: Double = 3.0
        static let optimalBPSMax: Double = 7.0
        /// Max seconds between two dribble events to count as a hand-switch combo.
        static let comboWindowSec: Double = 1.5
        /// Ball diameter in cm — used as scale reference.
        static let ballDiameterCm: Double = 24.0
        /// Rolling window duration (seconds) used for current BPS calculation.
        static let bpsWindowSec: Double = 3.0
        /// Number of AR floor targets per dribble drill.
        static let arTargetCount: Int = 3
        /// Radius of each AR floor target (metres).
        static let arTargetRadiusM: Float = 0.25
    }

    // MARK: - Skill Rating Algorithm
    enum SkillRating {
        static let maxRating:        Double = 100
        static let minRating:        Double = 0
        static let shootingWeight:   Double = 0.30   // contribution to overall
        static let handlingWeight:   Double = 0.20
        static let athleticismWeight: Double = 0.20
        static let consistencyWeight: Double = 0.15
        static let volumeWeight:     Double = 0.15
        /// Exponential moving average factor for skill rating updates (lower = slower to change).
        static let emaAlpha:         Double = 0.3
    }

    // MARK: - Storage
    enum Storage {
        static let sessionVideoDirectory  = "Sessions"
        static let maxSessionVideoMB      = 300       // per 30-min session
        static let defaultVideoRetainDays = 60
    }

    // MARK: - Performance Targets
    enum Performance {
        static let makeDetectionAccuracy:    Double = 0.92  // 92% under good indoor lighting
        static let poseEstimationErrorDeg:   Double = 3.0   // degrees
        static let maxMemoryFootprintMB:     Double = 300
        static let maxBatteryPerHourPercent: Double = 20
    }

    // MARK: - UI
    enum UI {
        static let cornerRadius: Double         = 16
        static let cardPadding: Double          = 14
        static let animationDuration: Double    = 0.3
        static let makeAnimationDuration: Double = 1.0
    }
}
