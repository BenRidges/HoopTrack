// CoordinatorHost.swift
// Builds SessionFinalizationCoordinator once ModelContext is available,
// then injects it as an environment object for all child views.

import SwiftUI
import SwiftData
import Combine

struct CoordinatorHost: View {
    @Environment(\.modelContext)    private var modelContext
    @EnvironmentObject private var notificationService: NotificationService
    @EnvironmentObject private var authViewModel: AuthViewModel

    @StateObject private var box = CoordinatorBox()

    var body: some View {
        Group {
            if let coordinator = box.value, let dataService = box.dataService {
                ContentView()
                    .environmentObject(coordinator)
                    .environmentObject(dataService)
            } else {
                ContentView()
                    .task {
                        box.build(modelContext: modelContext,
                                  notificationService: notificationService)
                    }
            }
        }
        .onChange(of: authViewModel.state) { _, newState in
            if case .authenticated(let user) = newState {
                try? box.dataService?.linkSupabaseUser(id: user.id.uuidString)
            }
        }
    }
}

/// Holds the coordinator as an optional, constructed lazily after ModelContext is available.
@MainActor final class CoordinatorBox: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var value: SessionFinalizationCoordinator? {
        willSet { objectWillChange.send() }
    }
    private(set) var dataService: DataService?

    func build(modelContext: ModelContext, notificationService: NotificationService) {
        guard value == nil, dataService == nil else { return }
        let ds = DataService(modelContext: modelContext)
        dataService = ds
        let retention = (try? ds.fetchOrCreateProfile().videosAutoDeleteDays)
            ?? HoopTrack.Storage.defaultVideoRetainDays
        if retention > 0 {
            try? ds.purgeOldVideos(olderThanDays: retention)
        }
        let telemetryCapture = TelemetryCaptureService(modelContext: modelContext)
        let telemetryUpload  = TelemetryUploadService(modelContext: modelContext)
        value = SessionFinalizationCoordinator(
            dataService:            ds,
            goalUpdateService:      GoalUpdateService(modelContext: modelContext),
            healthKitService:       HealthKitService(),
            skillRatingService:     SkillRatingService(modelContext: modelContext),
            badgeEvaluationService: BadgeEvaluationService(modelContext: modelContext),
            notificationService:    notificationService,
            syncCoordinator:        SyncCoordinator(),
            telemetryCaptureService: telemetryCapture,
            telemetryUploadService:  telemetryUpload
        )
        Task { await value?.requestHealthKitPermission() }

        // CV-A — drain any pending telemetry uploads left from a previous
        // launch (e.g. app killed mid-upload).
        Task { @MainActor in
            if let profile = try? ds.fetchOrCreateProfile(),
               let uidString = profile.supabaseUserID,
               let userID = UUID(uuidString: uidString) {
                await telemetryUpload.uploadPending(userID: userID)
            }
        }
    }
}
