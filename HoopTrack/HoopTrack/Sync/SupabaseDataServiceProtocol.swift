// HoopTrack/Sync/SupabaseDataServiceProtocol.swift
import Foundation

/// Interface for every Supabase read and write. Allows unit tests to inject
/// a MockSupabaseDataService and production to use the real PostgREST wrapper.
protocol SupabaseDataServiceProtocol: Sendable {
    /// Upsert the current user's profile row.
    func upsertProfile(_ dto: PlayerProfileDTO) async throws

    /// Upsert a training session row.
    func upsertSession(_ dto: TrainingSessionDTO) async throws

    /// Uploads shot records. Rows already in the cloud are skipped, or
    /// updated once `HoopTrack.Backend.shotRowsUpdatable` is on, so a retry
    /// never fails on a duplicate id.
    func upsertShots(_ dtos: [ShotRecordDTO]) async throws

    /// Upsert a goal.
    func upsertGoal(_ dto: GoalRecordDTO) async throws

    /// Upsert an earned badge. Uses (user_id, badge_id) uniqueness.
    func upsertBadge(_ dto: EarnedBadgeDTO) async throws

    // MARK: Restore — every row of the signed-in user's (RLS limits it)

    func fetchSessions() async throws -> [TrainingSessionDTO]
    func fetchShots() async throws -> [ShotRecordDTO]
    func fetchGoals() async throws -> [GoalRecordDTO]
    func fetchBadges() async throws -> [EarnedBadgeDTO]
}
