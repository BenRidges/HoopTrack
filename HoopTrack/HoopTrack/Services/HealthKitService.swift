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

        let workout = HKWorkout(
            activityType: .basketball,
            start: session.startedAt,
            end: endedAt,
            duration: session.durationSeconds,
            totalEnergyBurned: nil,
            totalDistance: nil,
            metadata: nil
        )
        try await store.save(workout)
    }
}
