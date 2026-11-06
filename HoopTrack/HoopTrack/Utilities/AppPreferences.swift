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
    }

    static var appLockEnabled: Bool    { UserDefaults.standard.bool(forKey: Key.appLockEnabled) }
    static var healthKitEnabled: Bool  { UserDefaults.standard.bool(forKey: Key.healthKitEnabled) }
    static var shareTrainingData: Bool { UserDefaults.standard.bool(forKey: Key.shareTrainingData) }
    static var trainingReminderEnabled: Bool { UserDefaults.standard.bool(forKey: Key.trainingReminderEnabled) }
    /// Matches the @AppStorage default in Profile (5 pm).
    static var trainingReminderHour: Int {
        UserDefaults.standard.object(forKey: Key.trainingReminderHour) as? Int ?? 17
    }

    /// Every key the app writes, plus legacy keys from older builds.
    static let allKeys: [String] = [
        Key.hasCompletedOnboarding, Key.appLockEnabled, Key.healthKitEnabled,
        Key.shareTrainingData, Key.showDetectionBoxes,
        Key.trainingReminderEnabled, Key.trainingReminderHour,
        "preferredCameraPosition", "selectedDrillType", "onboardingPlayerName",
    ]

    static func removeAll() {
        allKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
}
