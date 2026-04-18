// CoordinatorHost.swift
// Builds SessionFinalizationCoordinator once ModelContext is available,
// then injects it as an environment object for all child views.

import SwiftUI
import SwiftData
import Combine

struct CoordinatorHost: View {
    @Environment(\.modelContext)    private var modelContext
    @EnvironmentObject private var notificationService: NotificationService

    @StateObject private var box = CoordinatorBox()

    var body: some View {
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
        value = SessionFinalizationCoordinator(
            dataService:            ds,
            goalUpdateService:      GoalUpdateService(modelContext: modelContext),
            healthKitService:       HealthKitService(),
            skillRatingService:     SkillRatingService(modelContext: modelContext),
            badgeEvaluationService: BadgeEvaluationService(modelContext: modelContext),
            notificationService:    notificationService
        )
        Task { await value?.requestHealthKitPermission() }
    }
}
