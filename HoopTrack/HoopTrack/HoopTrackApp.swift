// HoopTrackApp.swift
// HoopTrack — Personal Basketball Progress Tracker
// iOS 16+ | SwiftUI + UIKit | MVVM + Combine
//
// Entry point. Configures the SwiftData model container (iOS 17+) and
// injects shared environment objects used across the entire tab hierarchy.

import SwiftUI
import SwiftData

// MARK: - Orientation Lock
/// App-wide flag that gates whether landscape orientations are permitted.
/// Set to `true` before presenting the live session; reset on dismiss.
enum OrientationLock {
    @MainActor static var allowLandscape: Bool = false
}

// MARK: - App Delegate (Orientation Gate)
final class HoopTrackAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.allowLandscape ? .landscape : .portrait
    }
}

@main
struct HoopTrackApp: App {
    @UIApplicationDelegateAdaptor(HoopTrackAppDelegate.self) var appDelegate

    // MARK: - SwiftData Container
    // SwiftData is used on iOS 17+. A Core Data fallback is documented in
    // DataService.swift for users still on iOS 16.
    let modelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: HoopTrackSchemaV3.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema,
                                       migrationPlan: HoopTrackMigrationPlan.self,
                                       configurations: [config])
        } catch {
#if DEBUG
            // Development fallback: wipe a corrupt/mismatched store rather than crashing.
            // This will never run in Release builds — safe to keep.
            print("⚠️ HoopTrack: ModelContainer load failed (\(error)). Wiping store for fresh start.")
            let storeURL = config.url
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("store-shm"))
            try? FileManager.default.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("store-wal"))
            do {
                return try ModelContainer(for: schema,
                                           migrationPlan: HoopTrackMigrationPlan.self,
                                           configurations: [config])
            } catch let retryError {
                fatalError("HoopTrack: ModelContainer still failed after wipe — \(retryError)")
            }
#else
            fatalError("HoopTrack: Failed to create ModelContainer — \(error)")
#endif
        }
    }()

    // MARK: - Shared Services (injected via environment)
    @StateObject private var hapticService       = HapticService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var cameraService       = CameraService()
    @StateObject private var appState            = AppState()
    @StateObject private var metricsService      = MetricsService()

    // MARK: - Onboarding Gate
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            CoordinatorHost()
                .modelContainer(modelContainer)
                .environmentObject(hapticService)
                .environmentObject(notificationService)
                .environmentObject(cameraService)
                .environmentObject(appState)
                .onOpenURL { appState.handleDeepLink($0) }
                .task { metricsService.register() }
                .fullScreenCover(isPresented: .init(
                    get: { !hasCompletedOnboarding },
                    set: { if !$0 { hasCompletedOnboarding = true } }
                )) {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                }
                .onAppear { configureSessionsDirectoryProtection() }
        }
    }

    // Phase 7 — Security
    private func configureSessionsDirectoryProtection() {
        let sessions = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory)

        // Create directory with protection if absent
        try? FileManager.default.createDirectory(
            at: sessions,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )

        // Re-apply protection to any pre-existing files
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sessions,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in contents {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        }
    }
}
