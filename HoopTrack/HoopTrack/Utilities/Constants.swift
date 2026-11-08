// Constants.swift
// App-wide constants. All magic numbers and configuration live here.

import Foundation

nonisolated enum HoopTrack {

    // MARK: - App Info
    static let appName    = "HoopTrack"
    static let bundleID   = "com.hooptrack.app"

    // MARK: - Camera / CV
    enum Camera {
        static let targetFPS: Double = 60
    }

    // MARK: - ML Model
    enum MLModel {
        /// Resource name of the bundled model (without extension). Xcode compiles
        /// `ML/BallDetector.mlmodel` to `BallDetector.mlmodelc`.
        static let bundledModelName = "BallDetector"
        /// Label substrings accepted for each class. The shipped model says
        /// "basket"; newer Roboflow exports say "rim". Accept both so a model
        /// swap can't silently switch hoop detection off again.
        static let ballLabels: [String] = ["ball"]
        static let hoopLabels: [String] = ["basket", "rim", "hoop"]

        /// Written into telemetry manifests so retrains can be matched to the
        /// model that produced the data. Update whenever BallDetector.mlmodel changes.
        static let modelVersion = "BallDetector-yolov8s-640-2026-04-18"
    }

    // MARK: - Shot detection
    enum CV {
        /// Per-class minimum confidence. The ball threshold is low on purpose:
        /// ShotTracker's temporal gating rejects one-frame false positives,
        /// and a blurred ball in flight often scores 0.3–0.5.
        static let ballConfidence: Float = 0.30
        static let hoopConfidence: Float = 0.45
        /// Shots below this confidence are flagged for review in the summary.
        static let lowConfidence: Double = 0.6
        /// While a shot is in flight, detect in a crop around the hoop and the
        /// ball (DetectionRegion) instead of the letterboxed full frame.
        /// Switch off here if boxes ever look misplaced with detection boxes on.
        static let focusDuringShots = true
        /// When the phone is this hot or hotter, detect on every other frame
        /// (recording continues at full rate) before iOS throttles for us.
        static let throttleAtThermalState = 2   // ProcessInfo.ThermalState.serious
        /// For this long after an automatic call, tapping the other result
        /// changes that call instead of logging another shot. Long enough to
        /// walk back to a phone 3 m away and tap twice; the next shot starting
        /// closes it sooner (shots come ~5 s apart).
        static let correctionWindowSec: Double = 8
    }

    // MARK: - Live session options (Profile → Session options)
    enum Session {
        /// A setup tip has to hold this long before it's shown (or said),
        /// so a jittery rim box doesn't flick between tips.
        static let setupSettleSec: Double = 1.2
        /// No shot for this long and the clock (and video) pause.
        static let idlePauseSec: Double = 120
        /// Paused this long: ask whether the session's over.
        static let idleAskSec: Double = 15 * 60
        /// Paused this long and nobody answered: end and save it.
        static let idleEndSec: Double = 20 * 60
        /// Screen dims after this long without a touch.
        static let dimAfterSec: Double = 20
    }

    // MARK: - Shot Science (Phase 3 thresholds)
    enum ShotScience {
        /// Launch-angle band coaches teach for jump shots, degrees.
        static let optimalReleaseAngleMin: Double = 43
        static let optimalReleaseAngleMax: Double = 57
    }

    // MARK: - Dribble (Phase 4 thresholds)
    enum Dribble {
        /// Wrist push needed to count a dribble, as a fraction of torso length.
        static let bounceThresholdTorso: Double = 0.12
        /// Comfortable dribbles-per-second band for the live speed readout.
        static let optimalBPSMin: Double = 3.0
        static let optimalBPSMax: Double = 7.0
        /// Rolling window (seconds) for the live BPS readout.
        static let bpsWindowSec: Double = 3.0
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
        static let defaultVideoRetainDays = 7
    }

    // MARK: - Game Mode
    enum Game {
        /// Default first-to score for pickup games (nil = no limit).
        static let defaultTargetScore: Int = 21
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
        /// `shot_records` is insert-only by policy, so a corrected result
        /// can't reach the cloud. Flip this once
        /// supabase/migrations/20261107000000_shot_record_updates.sql is applied.
        static let shotRowsUpdatable = false
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
        /// Where a password-reset email sends the user. Allow-list it too.
        static let passwordResetURL = URL(string: "hooptrack://auth/reset")!
    }

}
