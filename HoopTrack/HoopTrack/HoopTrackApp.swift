// HoopTrackApp.swift
// HoopTrack — Personal Basketball Progress Tracker
// iOS 16+ | SwiftUI + UIKit | MVVM + Combine
//
// Entry point. Configures the SwiftData model container (iOS 17+) and
// injects shared environment objects used across the entire tab hierarchy.

import SwiftUI
import SwiftData

// MARK: - Orientation Lock
/// App-wide gate for which interface orientations the app supports at any
/// given moment. Most of the app is portrait-locked (`.portraitOnly`).
/// LiveSessionView / LiveGameView force landscape (`.landscapeOnly`) via
/// LandscapeHostingController. Game registration opens things up with
/// `.all` so the user can hold the phone however they want while scanning
/// a player — AppearanceCaptureService handles orientation via the Vision
/// handler, not the window.
enum OrientationLock {
    enum Mode {
        case portraitOnly
        case landscapeOnly
        case all
    }

    @MainActor static var mode: Mode = .portraitOnly

    /// Legacy bool gate, kept so `LandscapeHostingController` can flip
    /// orientation in the narrow landscape-force case without knowing about
    /// the enum. Setting this flips between `.landscapeOnly` (true) and
    /// `.portraitOnly` (false), mirroring the old behaviour. Callers that
    /// want both orientations (game registration) set `mode = .all` directly.
    @MainActor static var allowLandscape: Bool {
        get { mode == .landscapeOnly }
        set { mode = newValue ? .landscapeOnly : .portraitOnly }
    }
}

// MARK: - App Delegate (Orientation Gate)
final class HoopTrackAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        switch OrientationLock.mode {
        case .portraitOnly:  return .portrait
        case .landscapeOnly: return .landscape
        case .all:           return .all
        }
    }
}

@main
struct HoopTrackApp: App {
    @UIApplicationDelegateAdaptor(HoopTrackAppDelegate.self) var appDelegate

    // MARK: - SwiftData Container
    // SwiftData is used on iOS 17+. A Core Data fallback is documented in
    // DataService.swift for users still on iOS 16.
    let modelContainer: ModelContainer = {
        // Flat schema list — SwiftData auto-handles additive changes like the
        // Phase 8 supabaseUserID: String? field. The explicit VersionedSchema
        // + MigrationPlan path is available in HoopTrackSchemaV1.swift /
        // HoopTrackMigrationPlan.swift if a future non-additive change needs it.
        let schema = Schema([
            PlayerProfile.self, TrainingSession.self,
            ShotRecord.self, GoalRecord.self, EarnedBadge.self,
            GamePlayer.self, GameSession.self, GameShotRecord.self,
            TelemetryUpload.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
#if DEBUG
            print("⚠️ HoopTrack: ModelContainer load failed (\(error)). Wiping store for fresh start.")
            let storeURL = config.url
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("store-shm"))
            try? FileManager.default.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("store-wal"))
            do {
                return try ModelContainer(for: schema, configurations: [config])
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
    @StateObject private var authViewModel       = AuthViewModel(provider: SupabaseAuthProvider())

    // MARK: - Onboarding Gate
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    // MARK: - Scene-phase lock tracking (Phase 8)
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundedAt: Date?

    var body: some Scene {
        WindowGroup {
            AuthGate {
                CoordinatorHost()
            }
            .environmentObject(authViewModel)
            .environmentObject(hapticService)
            .environmentObject(notificationService)
            .environmentObject(cameraService)
            .environmentObject(appState)
            .modelContainer(modelContainer)
            .task { await authViewModel.restore() }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhase(newPhase)
            }
            .onOpenURL { url in
                // Supabase auth callback lands here first; anything else is
                // an in-app deep link (Siri, notification tap) for AppState.
                if url.scheme?.lowercased() == "hooptrack",
                   url.host?.lowercased() == "auth" {
                    Task { await authViewModel.handleDeepLink(url) }
                } else {
                    appState.handleDeepLink(url)
                }
            }
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

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = Date()
        case .active:
            if let backgroundedAt,
               Date().timeIntervalSince(backgroundedAt) > HoopTrack.Auth.backgroundLockTimeoutSec {
                authViewModel.lock()
            }
            self.backgroundedAt = nil
        default:
            break
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
