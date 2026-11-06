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

    func upsertShots(_ dtos: [ShotRecordDTO]) async throws {
        guard !dtos.isEmpty else { return }
        let client = try await SupabaseContainer.postgrest()
        // "Ignore duplicates" is ON CONFLICT DO NOTHING, which the
        // insert-only policy allows; a plain insert failed the whole sync
        // as soon as one shot was already up.
        try await client
            .from("shot_records")
            .upsert(dtos, onConflict: "id", returning: .minimal,
                    ignoreDuplicates: !HoopTrack.Backend.shotRowsUpdatable)
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

    // MARK: - Restore

    func fetchSessions() async throws -> [TrainingSessionDTO] {
        try await fetchAll("training_sessions", orderedBy: "started_at")
    }

    func fetchShots() async throws -> [ShotRecordDTO] {
        try await fetchAll("shot_records", orderedBy: "timestamp")
    }

    func fetchGoals() async throws -> [GoalRecordDTO] {
        try await fetchAll("goal_records", orderedBy: "created_at")
    }

    func fetchBadges() async throws -> [EarnedBadgeDTO] {
        try await fetchAll("earned_badges", orderedBy: "earned_at")
    }

    /// Pages through a table: PostgREST returns at most 1000 rows a request.
    private func fetchAll<Row: Decodable & Sendable>(_ table: String, orderedBy column: String) async throws -> [Row] {
        let client = try await SupabaseContainer.postgrest()
        let page = 1000
        var rows: [Row] = []
        while true {
            let batch: [Row] = try await client
                .from(table)
                .select()
                .order(column)
                .range(from: rows.count, to: rows.count + page - 1)
                .execute()
                .value
            rows += batch
            if batch.count < page { return rows }
        }
    }
}
