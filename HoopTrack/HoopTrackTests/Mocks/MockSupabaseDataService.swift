// HoopTrackTests/Mocks/MockSupabaseDataService.swift
import Foundation
@testable import HoopTrack

final class MockSupabaseDataService: SupabaseDataServiceProtocol, @unchecked Sendable {

    /// Setting this makes every method throw.
    var scriptedError: Error?

    private(set) var profileUpserts: [PlayerProfileDTO] = []
    private(set) var sessionUpserts: [TrainingSessionDTO] = []
    private(set) var shotInserts:   [[ShotRecordDTO]] = []
    private(set) var goalUpserts:   [GoalRecordDTO] = []
    private(set) var badgeUpserts:  [EarnedBadgeDTO] = []

    func upsertProfile(_ dto: PlayerProfileDTO) async throws {
        try throwIfScripted()
        profileUpserts.append(dto)
    }

    func upsertSession(_ dto: TrainingSessionDTO) async throws {
        try throwIfScripted()
        sessionUpserts.append(dto)
    }

    func insertShots(_ dtos: [ShotRecordDTO]) async throws {
        try throwIfScripted()
        shotInserts.append(dtos)
    }

    func upsertGoal(_ dto: GoalRecordDTO) async throws {
        try throwIfScripted()
        goalUpserts.append(dto)
    }

    func upsertBadge(_ dto: EarnedBadgeDTO) async throws {
        try throwIfScripted()
        badgeUpserts.append(dto)
    }

    private func throwIfScripted() throws {
        if let err = scriptedError { throw err }
    }
}
