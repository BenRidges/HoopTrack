// HealthKitService.swift
import Foundation
import HealthKit

@MainActor final class HealthKitService: HealthKitServiceProtocol {

    private let store = HKHealthStore()

    func requestPermission() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
    }

    func writeWorkout(for session: TrainingSession) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else { return }
        guard let endedAt = session.endedAt else { return }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .basketball

        let builder = HKWorkoutBuilder(healthStore: store,
                                       configuration: configuration,
                                       device: .local())

        try await builder.beginCollection(at: session.startedAt)
        try await builder.endCollection(at: endedAt)
        _ = try await builder.finishWorkout()
    }
}
