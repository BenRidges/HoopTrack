// Constants.swift
// App-wide constants. All magic numbers and configuration live here.

import Foundation
import CoreGraphics

nonisolated enum HoopTrack {

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
        static let ballDetectionConfidenceThreshold: Float = 0.55
    }

    // MARK: - ML Model
    enum MLModel {
        /// Resource name of the bundled .mlpackage (without extension).
        static let bundledModelName  = "BallDetector"
        /// Target label for COCO-trained models (YOLOv8n, YOLOv5n, etc.)
        static let cocoTargetLabel   = "sports ball"
        /// Target label for basketball-specific models (Roboflow basketball-xil7x).
        /// Classes: ball, human, rim. Pipeline filters by substring so "ball"
        /// is the ball class and "rim" is queried separately in CoreMLBallDetector.
        static let customTargetLabel = "ball"

        /// Human-readable version string written into telemetry manifests so
        /// future retrains can correlate data with the model that was in use.
        /// Update whenever BallDetector.mlmodel is retrained/replaced.
        static let modelVersion = "BallDetector-yolo11m-2026-04-19"
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

        // MARK: Release angle
        static let releaseAngleOptimalMin:  Double = 43    // degrees — optimal band start
        static let releaseAngleOptimalMax:  Double = 57    // degrees — optimal band end
        static let releaseAngleFalloffMin:  Double = 30    // degrees — score = 0 below this
        static let releaseAngleFalloffMax:  Double = 70    // degrees — score = 0 above this
        static let releaseTimeEliteMs:      Double = 300   // ms — fastest expected release
        static let releaseTimeSlowMs:       Double = 800   // ms — slowest (score = 0)
        static let releaseAngleStdDevMax:   Double = 10    // degrees — worst accepted std dev

        // MARK: Shot speed
        static let shotSpeedOptimalMin:     Double = 18    // mph — optimal range start
        static let shotSpeedOptimalMax:     Double = 22    // mph — optimal range end
        static let shotSpeedStdDevMax:      Double = 5     // mph — worst accepted std dev

        // MARK: Ball handling
        static let bpsAvgMin:               Double = 2.0
        static let bpsAvgMax:               Double = 8.0
        static let bpsMaxMin:               Double = 3.0
        static let bpsMaxMax:               Double = 10.0
        static let bpsSustainedMin:         Double = 0.4   // avg/max ratio — low end
        static let bpsSustainedMax:         Double = 0.9   // avg/max ratio — elite end
        static let comboRateMax:            Double = 0.3   // combos / total dribbles cap

        // MARK: Athleticism
        static let verticalJumpMinCm:       Double = 20
        static let verticalJumpMaxCm:       Double = 90
        static let shuttleRunBestSec:       Double = 5.5   // elite shuttle run time
        static let shuttleRunWorstSec:      Double = 10.0  // slowest (score = 0)
        static let laneAgilityBestSec:      Double = 8.5
        static let laneAgilityWorstSec:     Double = 14.0

        // MARK: Consistency
        static let fgPctSessionStdDevMax:   Double = 30    // % — worst cross-session variance
        static let crossSessionMinCount:    Int    = 3     // min sessions for cross-session score

        // MARK: Badge gating
        /// Shooting sessions with fewer shots than this are excluded from badge evaluation entirely.
        static let badgeMinShotsForShootingSession: Int = 20

        // MARK: Volume
        static let sessionsPerWeekCap:      Double = 5
        static let shotsPerSessionMax:      Double = 200
        static let weeklyMinutesMax:        Double = 300
    }

    // MARK: - Storage
    enum Storage {
        static let sessionVideoDirectory  = "Sessions"
        static let maxSessionVideoMB      = 300       // per 30-min session
        static let defaultVideoRetainDays = 7
        static let allowedVideoRetainDays = [7, 14, 30]
    }

    // MARK: - Game Mode (SP1)
    enum Game {
        /// How long a valid body lock must hold before registration auto-advances.
        static let registrationLockDurationSec: Double = 3.0

        /// Minimum Vision body-pose keypoint confidence (shoulders + hips) to count as "valid lock".
        /// Was 0.7 — lowered to 0.5 after real-device testing revealed that Vision body-pose
        /// confidences typically sit in 0.3–0.7 even for clearly visible joints; requiring 0.7
        /// on all 4 joints simultaneously made the lock practically unachievable.
        static let registrationMinBodyConfidence: Float = 0.5

        /// How many consecutive bad frames the capture service coasts on a cached
        /// good reading before giving up and breaking the lock. At 30fps this is
        /// ~165ms — long enough for motion blur / AE shifts, short enough that
        /// a player actually walking away breaks the lock.
        static let registrationMaxStaleFrames: Int = 5

        /// Display hints for the user during registration (informational only).
        static let registrationMinDistanceFeet: Double = 6.0
        static let registrationMaxDistanceFeet: Double = 8.0

        /// Hard cap on team size — matches max `GameFormat` (3v3).
        static let maxPlayersPerTeam: Int = 3

        /// AppearanceDescriptor histogram dimensions.
        static let histogramHueBins: Int = 8
        static let histogramValueBins: Int = 4

        /// AppearanceDescriptor schema version — bump on breaking field changes.
        static let appearanceDescriptorSchemaVersion: Int = 1
    }

    // MARK: - Telemetry (CV-A)
    enum Telemetry {
        // Sampling
        static let baselineSampleFPS: Double = 1.0
        static let aroundShotPreFrames: Int = 10
        static let aroundShotPostFrames: Int = 10
        static let flickerThresholdHigh: Double = 0.6
        static let flickerThresholdLow: Double = 0.3
        static let flickerMinConsecutiveFrames: Int = 3
        static let boundaryFrames: Int = 5

        // Caps
        static let maxFramesPerSession: Int = 1000
        static let frameMaxLongestEdgePx: Int = 960
        static let frameJpegQuality: CGFloat = 0.7

        // Session eligibility
        static let minSessionDurationSec: Double = 30.0

        // Upload
        static let maxUploadAttempts: Int = 5
        static let concurrentFrameUploads: Int = 4
        static let uploadRequestTimeoutSec: TimeInterval = 60

        // Paths
        static let telemetryDirectoryName = "Telemetry"
        static let supabaseBucketName = "telemetry-sessions"

        // Dataset targets — informational, used by future dev tooling.
        // Not enforced at runtime.
        static let retrainTargetFrames: Int = 2000
        static let retrainTargetSessions: Int = 10
    }

    // MARK: - Performance Targets
    enum Performance {
        static let makeDetectionAccuracy:    Double = 0.92  // 92% under good indoor lighting
        static let poseEstimationErrorDeg:   Double = 3.0   // degrees
        static let maxMemoryFootprintMB:     Double = 300
        static let maxBatteryPerHourPercent: Double = 20
    }

    // Phase 7 — Security
    enum KeychainKey {
        static let accessToken    = "com.hooptrack.keychain.accessToken"
        static let refreshToken   = "com.hooptrack.keychain.refreshToken"
        static let userID         = "com.hooptrack.keychain.userID"
        static let biometricToken = "com.hooptrack.keychain.biometricToken"
    }

    // MARK: - Backend (Phase 8+)
    enum Backend {
        /// Supabase project URL — read from gitignored BackendSecrets.
        static var supabaseURL: URL { BackendSecrets.supabaseURL }
        /// Supabase anon / public key.
        static var supabaseAnonKey: String { BackendSecrets.supabaseAnonKey }
    }

    // MARK: - Auth (Phase 8)
    enum Auth {
        /// Re-lock after this many seconds of app backgrounding —
        /// biometric prompt required on return.
        static let backgroundLockTimeoutSec: TimeInterval = 60
        /// Minimum password length enforced client-side. Supabase enforces ≥ 6 server-side.
        static let minPasswordLength: Int = 8
        /// URL that Supabase embeds in confirmation emails. Must be allow-listed
        /// in the Supabase dashboard (Auth → URL Configuration → Redirect URLs).
        /// iOS routes the scheme back to the app via Info.plist CFBundleURLTypes.
        static let redirectURL = URL(string: "hooptrack://auth/callback")!
    }

    // MARK: - UI
    enum UI {
        static let cornerRadius: Double         = 16
        static let cardPadding: Double          = 14
        static let animationDuration: Double    = 0.3
        static let makeAnimationDuration: Double = 1.0
    }
}
