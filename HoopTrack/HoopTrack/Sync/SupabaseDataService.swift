// HoopTrack/Sync/SupabaseDataService.swift
import Foundation
import PostgREST

final class SupabaseDataService: SupabaseDataServiceProtocol, @unchecked Sendable {

    nonisolated init() {}

    func upsertProfile(_ dto: PlayerProfileDTO) async throws {
        let client = try await SupabaseContainer.postgrest()
        try await client
            .from("player_profiles")
            .upsert(dto, onConflict: "user_id")
            .execute()
    }

    func upsertSession(_ dto: TrainingSessionDTO) async throws {
        let client = try await SupabaseContainer.postgrest()
        try await client
            .from("training_sessions")
            .upsert(dto, onConflict: "id")
            .execute()
    }

    func insertShots(_ dtos: [ShotRecordDTO]) async throws {
        guard !dtos.isEmpty else { return }
        let client = try await SupabaseContainer.postgrest()
        try await client
            .from("shot_records")
            .insert(dtos)
            .execute()
    }

    func upsertGoal(_ dto: GoalRecordDTO) async throws {
        let client = try await SupabaseContainer.postgrest()
        try await client
            .from("goal_records")
            .upsert(dto, onConflict: "id")
            .execute()
    }

    func upsertBadge(_ dto: EarnedBadgeDTO) async throws {
        let client = try await SupabaseContainer.postgrest()
        try await client
            .from("earned_badges")
            .upsert(dto, onConflict: "user_id,badge_id")
            .execute()
    }
}
