// HoopTrack/Sync/SyncCoordinator.swift
// Keeps the local SwiftData store and the Supabase backup level.
//
// - After each session, SessionFinalizationCoordinator uploads it
//   (fire-and-forget: a network failure only leaves cloudSyncedAt nil).
// - backUpEverything uploads whatever hasn't made it yet: sessions from
//   before signing in, uploads that failed, corrections.
// - restore brings back rows this phone doesn't have (new phone,
//   reinstall). Matching is by id and local copies always win, so it never
//   changes or removes anything already here.

import Foundation
import SwiftData

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

        // Only shots not yet up: re-sending the rest is wasted work, and
        // the insert-only table can't take them again anyway.
        let pending = session.shots.filter { $0.cloudSyncedAt == nil }
        if !pending.isEmpty {
            try await backend.upsertShots(pending.map {
                ShotRecordDTO(from: $0, userID: userID, sessionID: session.id)
            })
        }

        let now = Date()
        session.cloudSyncedAt = now
        for shot in pending { shot.cloudSyncedAt = now }
    }

    // MARK: - Everything

    /// Uploads whatever isn't in the cloud yet. Profile, goals and badges
    /// are small and change over time, so they always go. Carries on past
    /// a failure and throws the first one at the end. Returns the number of
    /// sessions sent.
    @discardableResult
    func backUpEverything(userID: UUID, context: ModelContext) async throws -> Int {
        var firstError: Error?
        func attempt(_ work: () async throws -> Void) async {
            do { try await work() } catch { if firstError == nil { firstError = error } }
        }

        if let profile = try context.fetch(FetchDescriptor<PlayerProfile>()).first {
            await attempt { try await syncProfile(profile, userID: userID) }
        }
        let sessions = try context.fetch(FetchDescriptor<TrainingSession>()).filter { session in
            session.endedAt != nil
                && (session.cloudSyncedAt == nil || session.shots.contains { $0.cloudSyncedAt == nil })
        }
        for session in sessions {
            await attempt { try await syncSession(session, userID: userID) }
        }
        for goal in try context.fetch(FetchDescriptor<GoalRecord>()) {
            await attempt { try await syncGoal(goal, userID: userID) }
        }
        for badge in try context.fetch(FetchDescriptor<EarnedBadge>()) {
            await attempt { try await syncBadge(badge, userID: userID) }
        }
        try context.save()
        if let firstError { throw firstError }
        return sessions.count
    }

    struct RestoreReport: Equatable, Sendable {
        var sessions = 0
        var shots = 0
        var goals = 0
        var badges = 0
        var isEmpty: Bool { sessions + goals + badges == 0 }
    }

    /// Adds the backed-up sessions (with their shots), goals and badges
    /// this phone doesn't have. Shots are only added to sessions restored
    /// now, never to ones already here, so a shot deleted on this phone
    /// doesn't come back.
    func restore(userID: UUID, context: ModelContext) async throws -> RestoreReport {
        let remoteSessions = try await backend.fetchSessions()
        let remoteGoals = try await backend.fetchGoals()
        let remoteBadges = try await backend.fetchBadges()

        var report = RestoreReport()
        let profile = try context.fetch(FetchDescriptor<PlayerProfile>()).first
        let now = Date()

        let localSessions = Set(try context.fetch(FetchDescriptor<TrainingSession>()).map(\.id))
        var restored: [UUID: TrainingSession] = [:]
        for dto in remoteSessions where !localSessions.contains(dto.id) {
            let session = dto.makeSession(syncedAt: now)
            session.profile = profile
            context.insert(session)
            restored[session.id] = session
        }
        report.sessions = restored.count

        if !restored.isEmpty {
            for dto in try await backend.fetchShots() {
                guard let session = restored[dto.sessionId], let shot = dto.makeShot(syncedAt: now) else { continue }
                context.insert(shot)
                shot.session = session
                session.shots.append(shot)
                report.shots += 1
            }
        }

        let localGoals = Set(try context.fetch(FetchDescriptor<GoalRecord>()).map(\.id))
        for dto in remoteGoals where !localGoals.contains(dto.id) {
            guard let goal = dto.makeGoal(syncedAt: now) else { continue }
            goal.profile = profile
            context.insert(goal)
            report.goals += 1
        }

        // One badge of each kind: a badge earned here already is kept.
        var localBadges = Set(try context.fetch(FetchDescriptor<EarnedBadge>()).map(\.badgeID))
        for dto in remoteBadges {
            guard let badge = dto.makeBadge(syncedAt: now), !localBadges.contains(badge.badgeID) else { continue }
            badge.profile = profile
            context.insert(badge)
            localBadges.insert(badge.badgeID)
            report.badges += 1
        }

        try context.save()
        return report
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
