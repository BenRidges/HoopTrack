// AppServices.swift
// AppServices: every long-lived service, built once at launch from the
// shared SwiftData container and injected into the view tree.
//
// Previously a CoordinatorHost view built these lazily in `.task`, which
// rendered the whole tab tree once *without* DataService/coordinator in
// the environment (any screen touching them crashed) and then rebuilt it
// from scratch when they arrived.

import SwiftUI
import SwiftData
import Combine

@MainActor
final class AppServices: ObservableObject {
    deinit {} // Keep: see "Explicit deinit" in CLAUDE.md


    let container: ModelContainer
    let dataService: DataService
    let coordinator: SessionFinalizationCoordinator
    let hapticService = HapticService()
    /// Calls shots out loud; outlives a session so its last words finish.
    let announcer = SessionAnnouncer()
    let notificationService: NotificationService
    let cameraService = CameraService()
    let appState = AppState()
    let appLock = AppLock()
    let metricsService = MetricsService()
    let syncCoordinator = SyncCoordinator()
    private let telemetryUpload: TelemetryUploadService
    private var isSyncing = false

    /// `container` defaults to the app's on-disk store.
    init(container: ModelContainer? = nil) {
        let container = container ?? HoopTrackStore.shared
        self.container = container
        let context = container.mainContext
        let dataService = DataService(modelContext: context)
        let telemetryUpload = TelemetryUploadService(modelContext: context)
        let notificationService = NotificationService()
        self.notificationService = notificationService
        self.dataService = dataService
        self.telemetryUpload = telemetryUpload
        self.coordinator = SessionFinalizationCoordinator(
            dataService:            dataService,
            goalUpdateService:      GoalUpdateService(modelContext: context),
            healthKitService:       HealthKitService(),
            skillRatingService:     SkillRatingService(modelContext: context),
            badgeEvaluationService: BadgeEvaluationService(modelContext: context),
            notificationService:    notificationService,
            syncCoordinator:        syncCoordinator,
            telemetryCaptureService: TelemetryCaptureService(modelContext: context),
            telemetryUploadService:  telemetryUpload
        )
    }

    /// Housekeeping once per launch.
    func onLaunch() {
        metricsService.register()
        protectSessionFiles()

        let profile = try? dataService.fetchOrCreateProfile()
        let retention = profile?.videosAutoDeleteDays ?? HoopTrack.Storage.defaultVideoRetainDays
        if retention > 0 { try? dataService.purgeOldVideos(olderThanDays: retention) }
        // Streaks age even when you don't train; refresh on every launch.
        try? dataService.recomputeCareerStats()
        // Keep the reminder window rolling.
        notificationService.refreshTrainingReminders(trainedToday: dataService.hasTrainedToday)

        // CV-A — clear what can't be sent, then drain uploads left over from
        // a previous launch (opt-in only). Nothing is recording at launch.
        telemetryUpload.tidyUp()
        if let uid = profile?.supabaseUserID.flatMap(UUID.init(uuidString:)) {
            Task { await telemetryUpload.uploadPending(userID: uid) }
        }
    }

    // MARK: - Cloud backup

    /// Runs when a verified user is signed in (at launch, or on signing in).
    /// A phone with no history of its own gets the backup restored first.
    /// That covers a new phone or a reinstall. Merging into an existing
    /// history only happens from Profile → Restore from backup, because a
    /// session deleted here still exists in the cloud and would come back.
    /// Then anything not yet backed up is uploaded.
    func syncCloudBackup(userID: UUID) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let context = dataService.modelContext
        let hasHistory = ((try? context.fetchCount(FetchDescriptor<TrainingSession>())) ?? 0) > 0
        if !hasHistory, let report = try? await syncCoordinator.restore(userID: userID, context: context),
           !report.isEmpty {
            try? dataService.recomputeCareerStats()
        }
        _ = try? await syncCoordinator.backUpEverything(userID: userID, context: context)
    }

    /// Profile → Restore from backup: adds whatever's in the cloud and not here.
    func restoreFromBackup(userID: UUID) async throws -> SyncCoordinator.RestoreReport {
        let report = try await syncCoordinator.restore(userID: userID, context: dataService.modelContext)
        if !report.isEmpty { try? dataService.recomputeCareerStats() }
        return report
    }

    // Phase 7 — Security: (re)apply complete protection to session videos.
    private func protectSessionFiles() {
        let fm = FileManager.default
        let dir = SessionRecorder.directory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.complete])
        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        }
    }
}

extension View {
    /// Injects every app service. Needed at the root and again inside
    /// UIKit-hosted content (LandscapeContainer), which doesn't inherit the
    /// SwiftUI environment.
    func appEnvironment(_ services: AppServices, auth: AuthViewModel) -> some View {
        self
            .environmentObject(services)
            .environmentObject(services.dataService)
            .environmentObject(services.coordinator)
            .environmentObject(services.hapticService)
            .environmentObject(services.announcer)
            .environmentObject(services.notificationService)
            .environmentObject(services.cameraService)
            .environmentObject(services.appState)
            .environmentObject(services.appLock)
            .environmentObject(auth)
            .modelContainer(services.container)
            .preferredColorScheme(.dark)
            .tint(.leather)
    }
}
