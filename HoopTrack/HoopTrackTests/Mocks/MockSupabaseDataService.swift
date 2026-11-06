// HoopTrackTests/Mocks/MockSupabaseDataService.swift
import Foundation
@testable import HoopTrack

final class MockSupabaseDataService: SupabaseDataServiceProtocol, @unchecked Sendable {

    /// Setting this makes every method throw.
    var scriptedError: Error?

    private(set) var profileUpserts: [PlayerProfileDTO] = []
    private(set) var sessionUpserts: [TrainingSessionDTO] = []
    private(set) var shotUpserts:   [[ShotRecordDTO]] = []
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

    func upsertShots(_ dtos: [ShotRecordDTO]) async throws {
        try throwIfScripted()
        shotUpserts.append(dtos)
    }

    func upsertGoal(_ dto: GoalRecordDTO) async throws {
        try throwIfScripted()
        goalUpserts.append(dto)
    }

    func upsertBadge(_ dto: EarnedBadgeDTO) async throws {
        try throwIfScripted()
        badgeUpserts.append(dto)
    }

    // MARK: Restore

    var remoteSessions: [TrainingSessionDTO] = []
    var remoteShots: [ShotRecordDTO] = []
    var remoteGoals: [GoalRecordDTO] = []
    var remoteBadges: [EarnedBadgeDTO] = []

    func fetchSessions() async throws -> [TrainingSessionDTO] { try throwIfScripted(); return remoteSessions }
    func fetchShots() async throws -> [ShotRecordDTO] { try throwIfScripted(); return remoteShots }
    func fetchGoals() async throws -> [GoalRecordDTO] { try throwIfScripted(); return remoteGoals }
    func fetchBadges() async throws -> [EarnedBadgeDTO] { try throwIfScripted(); return remoteBadges }

    private func throwIfScripted() throws {
        if let err = scriptedError { throw err }
    }
}
