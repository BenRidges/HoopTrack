// HoopTrackApp.swift
// HoopTrack — Personal Basketball Progress Tracker
// iOS 16+ | SwiftUI + UIKit | MVVM + Combine
//
// Entry point. Configures the SwiftData model container (iOS 17+) and
// injects shared environment objects used across the entire tab hierarchy.

import SwiftUI
import SwiftData

@main
struct HoopTrackApp: App {

    // MARK: - SwiftData Container
    // SwiftData is used on iOS 17+. A Core Data fallback is documented in
    // DataService.swift for users still on iOS 16.
    let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(
                for: PlayerProfile.self, TrainingSession.self,
                     ShotRecord.self, GoalRecord.self, EarnedBadge.self,
                migrationPlan: HoopTrackMigrationPlan.self
            )
        } catch {
            fatalError("HoopTrack: Failed to create ModelContainer — \(error)")
        }
    }()

    // MARK: - Shared Services (injected via environment)
    @StateObject private var hapticService    = HapticService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var cameraService   = CameraService()

    // MARK: - Onboarding Gate
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            CoordinatorHost()
                .modelContainer(modelContainer)
                .environmentObject(hapticService)
                .environmentObject(notificationService)
                .environmentObject(cameraService)
                .fullScreenCover(isPresented: .init(
                    get: { !hasCompletedOnboarding },
                    set: { if !$0 { hasCompletedOnboarding = true } }
                )) {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                }
        }
    }
}
