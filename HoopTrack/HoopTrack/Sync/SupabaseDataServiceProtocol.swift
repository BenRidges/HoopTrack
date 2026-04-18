// HoopTrack/Sync/SupabaseDataServiceProtocol.swift
import Foundation

/// Interface for every Supabase write operation. Allows unit tests to inject
/// a MockSupabaseDataService and production to use the real PostgREST wrapper.
protocol SupabaseDataServiceProtocol: Sendable {
    /// Upsert the current user's profile row.
    func upsertProfile(_ dto: PlayerProfileDTO) async throws

    /// Upsert a training session row.
    func upsertSession(_ dto: TrainingSessionDTO) async throws

    /// Insert shot records — append-only; upsert fails by RLS design.
    func insertShots(_ dtos: [ShotRecordDTO]) async throws

    /// Upsert a goal.
    func upsertGoal(_ dto: GoalRecordDTO) async throws

    /// Upsert an earned badge. Uses (user_id, badge_id) uniqueness.
    func upsertBadge(_ dto: EarnedBadgeDTO) async throws
}
