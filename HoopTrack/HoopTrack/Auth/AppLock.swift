// AppLock.swift
// Optional Face ID / passcode lock (Profile → Privacy). Independent of
// signing in: it protects the training data on this phone whether or not
// there's a cloud account. Re-locks after the app has been in the
// background for HoopTrack.Auth.backgroundLockTimeoutSec.

import SwiftUI
import Combine
import LocalAuthentication

@MainActor
final class AppLock: ObservableObject {
    deinit {} // Keep: see "Explicit deinit" in CLAUDE.md


    @Published private(set) var isLocked = false
    private var backgroundedAt: Date?

    /// Call once at launch.
    func lockAtLaunchIfEnabled() {
        isLocked = AppPreferences.appLockEnabled
    }

    func sceneChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = .now
        case .active:
            if AppPreferences.appLockEnabled, let backgroundedAt,
               Date.now.timeIntervalSince(backgroundedAt) > HoopTrack.Auth.backgroundLockTimeoutSec {
                isLocked = true
            }
            backgroundedAt = nil
        default:
            break
        }
    }

    /// Face ID / Touch ID with passcode fallback. Returns an error message on failure.
    func unlock() async -> String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set on the device: nothing to lock with.
            isLocked = false
            return nil
        }
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                localizedReason: "Unlock your training history") {
                isLocked = false
            }
            return nil
        } catch {
            return (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
        }
    }

    /// Verifies the owner before turning the lock on, so nobody locks themselves out.
    func confirmEnable() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: "Turn on the app lock")) ?? false
    }
}
