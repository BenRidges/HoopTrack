// AppPreferences.swift
// UserDefaults keys for non-sensitive UI preferences. Views bind with
// @AppStorage(AppPreferences.Key.x); services read the static helpers.
// Sensitive values never go here — see KeychainService.

import Foundation

nonisolated enum AppPreferences {

    enum Key {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        /// Face ID lock after backgrounding. Off by default.
        static let appLockEnabled         = "appLockEnabled"
        /// Write sessions to Apple Health as workouts. Off by default.
        static let healthKitEnabled       = "healthKitEnabled"
        /// Upload sampled frames to help improve shot detection. Off by default.
        static let shareTrainingData      = "shareTrainingData"
        /// Draw detector boxes over the camera. Developer aid.
        static let showDetectionBoxes     = "showDetectionBoxes"
        static let trainingReminderEnabled = "trainingReminderEnabled"
        static let trainingReminderHour   = "trainingReminderHour"

        // Session options (Profile → Session options). All on by default;
        // each one is a single switch so it can be turned off on its own.
        /// ShotCallMode raw value: say each call, play a sound, or neither.
        static let shotCalls              = "shotCalls"
        /// Live tips on where the phone is ("Too close", "Good spot").
        static let setupCoach             = "setupCoach"
        /// "Spot 2 of 5 · Right wing · 3 to go" in named drills.
        static let drillGuidance          = "drillGuidance"
        /// A timed drill's clock waits for the first shot.
        static let timedDrillsWaitForShot = "timedDrillsWaitForShot"
        /// Pause the clock (and the video) when nobody's shooting.
        static let autoPause              = "autoPause"
        /// Dim the screen during a shooting session until it's touched.
        static let dimDuringSessions      = "dimDuringSessions"
        /// Your best (or your goal) on the live screen.
        static let showTarget             = "showTarget"
        /// Flagged calls are checked by watching each one's clip.
        static let reviewOnVideo          = "reviewOnVideo"
        /// "Go again" on the summary.
        static let goAgain                = "goAgain"
    }

    static var appLockEnabled: Bool    { UserDefaults.standard.bool(forKey: Key.appLockEnabled) }
    static var healthKitEnabled: Bool  { UserDefaults.standard.bool(forKey: Key.healthKitEnabled) }
    static var shareTrainingData: Bool { UserDefaults.standard.bool(forKey: Key.shareTrainingData) }
    static var trainingReminderEnabled: Bool { UserDefaults.standard.bool(forKey: Key.trainingReminderEnabled) }
    /// Matches the @AppStorage default in Profile (5 pm).
    static var trainingReminderHour: Int {
        UserDefaults.standard.object(forKey: Key.trainingReminderHour) as? Int ?? 17
    }

    /// Session options read at the start of a session.
    static var sessionOptions: SessionOptions {
        let defaults = UserDefaults.standard
        func on(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        return SessionOptions(
            shotCalls: defaults.string(forKey: Key.shotCalls).flatMap { ShotCallMode(rawValue: $0) } ?? .voice,
            setupCoach: on(Key.setupCoach),
            drillGuidance: on(Key.drillGuidance),
            timedDrillsWaitForShot: on(Key.timedDrillsWaitForShot),
            autoPause: on(Key.autoPause),
            dimScreen: on(Key.dimDuringSessions),
            showTarget: on(Key.showTarget))
    }
    static var reviewOnVideo: Bool { UserDefaults.standard.object(forKey: Key.reviewOnVideo) as? Bool ?? true }
    static var goAgain: Bool { UserDefaults.standard.object(forKey: Key.goAgain) as? Bool ?? true }

    /// Every key the app writes, plus legacy keys from older builds.
    static let allKeys: [String] = [
        Key.hasCompletedOnboarding, Key.appLockEnabled, Key.healthKitEnabled,
        Key.shareTrainingData, Key.showDetectionBoxes,
        Key.trainingReminderEnabled, Key.trainingReminderHour,
        Key.shotCalls, Key.setupCoach, Key.drillGuidance, Key.timedDrillsWaitForShot,
        Key.autoPause, Key.dimDuringSessions, Key.showTarget, Key.reviewOnVideo, Key.goAgain,
        "preferredCameraPosition", "selectedDrillType", "onboardingPlayerName",
    ]

    static func removeAll() {
        allKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
}

/// How each call is announced during a shooting session.
nonisolated enum ShotCallMode: String, CaseIterable, Identifiable, Sendable {
    /// "Make. 7 for 10." Tips and drill steps are spoken too.
    case voice
    /// A swish or a clank; a chime for tips and drill steps.
    case sounds
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .voice:  return "Voice"
        case .sounds: return "Sounds"
        case .off:    return "Off"
        }
    }
}

/// The session options in force for one shooting session. Read once at the
/// start (`AppPreferences.sessionOptions`); tests pass their own.
nonisolated struct SessionOptions: Equatable, Sendable {
    var shotCalls: ShotCallMode = .voice
    var setupCoach = true
    var drillGuidance = true
    var timedDrillsWaitForShot = true
    var autoPause = true
    var dimScreen = true
    var showTarget = true

    /// Everything off: what sessions did before these options existed.
    static let none = SessionOptions(shotCalls: .off, setupCoach: false, drillGuidance: false,
                                     timedDrillsWaitForShot: false, autoPause: false,
                                     dimScreen: false, showTarget: false)
}
