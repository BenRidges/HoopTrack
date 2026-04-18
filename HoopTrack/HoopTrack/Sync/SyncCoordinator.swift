// HoopTrack/Sync/SyncCoordinator.swift
// Orchestrates uploads from the local SwiftData store to Supabase.
// Fire-and-forget from SessionFinalizationCoordinator: network failure
// is non-fatal, only the cloudSyncedAt stamp is skipped.

import Foundation

@MainActor
final class SyncCoordinator {

    private let backend: SupabaseDataServiceProtocol

    init(backend: SupabaseDataServiceProtocol = SupabaseDataService()) {
        self.backend = backend
    }

    // MARK: - Session + shots

    /// Upsert a training session and all its shots. Stamps cloudSyncedAt on
    /// both the session and every shot on success; leaves them nil on
    /// failure so a future sync pass will re-upload.
    func syncSession(_ session: TrainingSession, userID: UUID) async throws {
        try await backend.upsertSession(TrainingSessionDTO(from: session, userID: userID))

        if !session.shots.isEmpty {
            let shotDTOs = session.shots.map {
                ShotRecordDTO(from: $0, userID: userID, sessionID: session.id)
            }
            try await backend.insertShots(shotDTOs)
        }

        let now = Date()
        session.cloudSyncedAt = now
        for shot in session.shots { shot.cloudSyncedAt = now }
    }

    // MARK: - Profile

    func syncProfile(_ profile: PlayerProfile, userID: UUID) async throws {
        try await backend.upsertProfile(PlayerProfileDTO(from: profile, userID: userID))
        profile.cloudSyncedAt = Date()
    }

    // MARK: - Goal

    func syncGoal(_ goal: GoalRecord, userID: UUID) async throws {
        try await backend.upsertGoal(GoalRecordDTO(from: goal, userID: userID))
        goal.cloudSyncedAt = Date()
    }

    // MARK: - Badge

    func syncBadge(_ badge: EarnedBadge, userID: UUID) async throws {
        try await backend.upsertBadge(EarnedBadgeDTO(from: badge, userID: userID))
        badge.cloudSyncedAt = Date()
    }
}
