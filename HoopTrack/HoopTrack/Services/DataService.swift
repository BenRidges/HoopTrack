// DataService.swift
// Abstraction layer over SwiftData (iOS 17+) / Core Data (iOS 16 fallback).
//
// All ViewModels interact with this service rather than directly with the
// ModelContext, keeping the data layer swappable without touching the UI.

import Foundation
import SwiftData
import Combine

// Phase 7 — Security: typed errors for validation failures in DataService.
enum DataServiceError: LocalizedError {
    case invalidSensorValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidSensorValue(let detail):
            return "Invalid sensor value rejected before persistence: \(detail)"
        }
    }
}

@MainActor
final class DataService: ObservableObject {

    // MARK: - Dependencies
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Player Profile

    /// Returns the single PlayerProfile, creating one if it doesn't exist.
    func fetchOrCreateProfile() throws -> PlayerProfile {
        let descriptor = FetchDescriptor<PlayerProfile>()
        let profiles   = try modelContext.fetch(descriptor)
        if let existing = profiles.first { return existing }

        let profile = PlayerProfile()
        modelContext.insert(profile)
        try modelContext.save()
        return profile
    }

    /// Associates the active PlayerProfile with a Supabase user id. Safe to
    /// call with the same id repeatedly — no-ops if the value matches.
    /// Phase 9 backend sync reads this field to key RLS on auth.uid().
    func linkSupabaseUser(id: String) throws {
        let profile = try fetchOrCreateProfile()
        if profile.supabaseUserID != id {
            profile.supabaseUserID = id
            try modelContext.save()
        }
    }

    // MARK: - Sessions

    func fetchSessions(sortBy: SortDescriptor<TrainingSession> =
                           SortDescriptor(\.startedAt, order: .reverse),
                       limit: Int? = nil) throws -> [TrainingSession] {
        var descriptor = FetchDescriptor<TrainingSession>(sortBy: [sortBy])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

    func fetchSessions(drillType: DrillType) throws -> [TrainingSession] {
        let predicate = #Predicate<TrainingSession> { $0.drillType == drillType }
        let descriptor = FetchDescriptor(predicate: predicate,
                                         sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try modelContext.fetch(descriptor)
    }

    /// Fetches sessions that started on or after `date`, most recent first.
    /// Pass a `limit` to avoid full-table scans when only recent data is needed.
    func fetchSessions(since date: Date, limit: Int? = nil) throws -> [TrainingSession] {
        let predicate  = #Predicate<TrainingSession> { $0.startedAt >= date }
        var descriptor = FetchDescriptor(predicate: predicate,
                                         sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

    /// Total shots attempted across all sessions that started today.
    /// Used by ShotsTodayIntent for the background spoken response.
    func fetchShotsTodayCount() throws -> Int {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let predicate  = #Predicate<TrainingSession> { $0.startedAt >= startOfDay }
        let descriptor = FetchDescriptor(predicate: predicate)
        let todaySessions = try modelContext.fetch(descriptor)
        return todaySessions.reduce(0) { $0 + $1.shotsAttempted }
    }

    func startSession(drillType: DrillType,
                      namedDrill: NamedDrill? = nil,
                      courtType: CourtType = .nba,
                      locationTag: String = "") throws -> TrainingSession {
        // Phase 7 — Security: sanitise free-text location tag before persisting
        let safeTag: String
        if locationTag.isEmpty {
            safeTag = ""
        } else {
            let stripped = locationTag.unicodeScalars
                .filter { !CharacterSet.controlCharacters.union(.illegalCharacters).contains($0) }
                .reduce("") { $0 + String($1) }
            safeTag = String(stripped.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        }
        let session = TrainingSession(drillType: drillType,
                                     namedDrill: namedDrill,
                                     courtType: courtType,
                                     locationTag: safeTag)
        let profile = try fetchOrCreateProfile()
        session.profile = profile
        profile.sessions.append(session)
        modelContext.insert(session)
        try modelContext.save()
        return session
    }

    func finaliseSession(_ session: TrainingSession) throws {
        session.endedAt          = .now
        session.durationSeconds  = session.endedAt!.timeIntervalSince(session.startedAt)
        session.recalculateStats()
        try modelContext.save()

        // Update profile aggregate stats
        let profile = try fetchOrCreateProfile()
        updateProfileStats(profile, with: session)
        try modelContext.save()
    }

    /// Finalises a dribble drill session. Applies live dribble metrics to the session model,
    /// stamps endedAt, and updates the player profile's ball-handling rating.
    func finaliseDribbleSession(_ session: TrainingSession,
                                metrics: DribbleLiveMetrics) throws {
        let now = Date.now
        session.endedAt         = now
        session.durationSeconds = now.timeIntervalSince(session.startedAt)
        session.applyDribbleMetrics(metrics, durationSec: session.durationSeconds)
        try modelContext.save()

        let profile = try fetchOrCreateProfile()
        updateProfileStats(profile, with: session)
        try modelContext.save()
    }

    func deleteSession(_ session: TrainingSession) throws {
        modelContext.delete(session)
        try modelContext.save()
    }

    // MARK: - Shots

    func addShot(to session: TrainingSession,
                 result: ShotResult,
                 zone: CourtZone,
                 shotType: ShotType,
                 courtX: Double,
                 courtY: Double,
                 science: ShotScienceMetrics? = nil) throws -> ShotRecord {
        // Phase 7 — Security: validate sensor inputs before persistence
        guard InputValidator.isValidCourtCoordinate(courtX),
              InputValidator.isValidCourtCoordinate(courtY) else {
            throw DataServiceError.invalidSensorValue("Court coordinates out of 0–1 range: (\(courtX), \(courtY))")
        }

        let shot = ShotRecord(
            sequenceIndex: session.shots.count + 1,
            result: result,
            zone: zone,
            shotType: shotType,
            courtX: courtX,
            courtY: courtY
        )
        shot.session = session
        session.shots.append(shot)

        // Set video timestamp so the replay view can seek to this shot
        shot.videoTimestampSeconds = shot.timestamp.timeIntervalSince(session.startedAt)

        // Apply Shot Science metrics if available (validate ranges before persisting)
        if let s = science {
            if let angle = s.releaseAngleDeg {
                shot.releaseAngleDeg = InputValidator.isValidReleaseAngle(angle) ? angle : nil
            }
            shot.releaseTimeMs   = s.releaseTimeMs
            if let jump = s.verticalJumpCm {
                shot.verticalJumpCm = InputValidator.isValidJumpHeight(jump) ? jump : nil
            }
            shot.legAngleDeg     = s.legAngleDeg
            shot.shotSpeedMph    = s.shotSpeedMph
        }

        session.recalculateStats()
        modelContext.insert(shot)
        try modelContext.save()
        return shot
    }

    func updateShot(_ shot: ShotRecord,
                    result: ShotResult? = nil,
                    courtX: Double? = nil,
                    courtY: Double? = nil) throws {
        if let result  = result  { shot.result  = result  }
        // Phase 7 — Security: validate court coordinates before persisting user corrections
        if let x = courtX {
            guard InputValidator.isValidCourtCoordinate(x) else {
                throw DataServiceError.invalidSensorValue("courtX out of 0–1 range: \(x)")
            }
            shot.courtX = x
        }
        if let y = courtY {
            guard InputValidator.isValidCourtCoordinate(y) else {
                throw DataServiceError.invalidSensorValue("courtY out of 0–1 range: \(y)")
            }
            shot.courtY = y
        }
        shot.isUserCorrected = true
        shot.session?.recalculateStats()
        try modelContext.save()
    }

    /// Called by CVPipeline to resolve a pending shot with its final make/miss result.
    /// Does NOT set isUserCorrected — only user-initiated edits set that flag.
    func resolveShot(_ shot: ShotRecord,
                     result: ShotResult,
                     zone: CourtZone,
                     courtX: Double,
                     courtY: Double) throws {
        // Phase 7 — Security: validate CV-produced court coordinates before persisting
        guard InputValidator.isValidCourtCoordinate(courtX),
              InputValidator.isValidCourtCoordinate(courtY) else {
            throw DataServiceError.invalidSensorValue("CV court coordinates out of 0–1 range: (\(courtX), \(courtY))")
        }
        shot.result  = result
        shot.zone    = zone
        shot.courtX  = courtX
        shot.courtY  = courtY
        shot.session?.recalculateStats()
        try modelContext.save()
    }

    // MARK: - Goals

    func addGoal(_ goal: GoalRecord, to profile: PlayerProfile) throws {
        goal.profile = profile
        profile.goals.append(goal)
        modelContext.insert(goal)
        try modelContext.save()
    }

    func updateGoalProgress(_ goal: GoalRecord, currentValue: Double) throws {
        goal.currentValue = currentValue
        if !goal.isAchieved && currentValue >= goal.targetValue {
            goal.isAchieved  = true
            goal.achievedAt  = .now
        }
        try modelContext.save()
    }

    func deleteGoal(_ goal: GoalRecord) throws {
        modelContext.delete(goal)
        try modelContext.save()
    }

    // Phase 7 — Security / GDPR right-to-delete
    /// Permanently removes all user data: SwiftData records, session videos,
    /// Keychain entries, app-level UserDefaults keys, and any exported JSON
    /// temp files written by ExportService.
    /// Call this when the user deletes their account.
    func deleteAllUserData() async {
        // 1. Delete all SwiftData model instances (EarnedBadge included — cascade from
        //    PlayerProfile handles it, but we delete explicitly first for safety)
        do {
            let sessions = try modelContext.fetch(FetchDescriptor<TrainingSession>())
            sessions.forEach { modelContext.delete($0) }

            let goals = try modelContext.fetch(FetchDescriptor<GoalRecord>())
            goals.forEach { modelContext.delete($0) }

            // Phase 7 — Security: EarnedBadge records must be deleted explicitly;
            // they are cascade-deleted from PlayerProfile but the cascade only fires
            // when the profile is deleted. Deleting here first avoids orphan risk
            // if the profile fetch/delete fails.
            let badges = try modelContext.fetch(FetchDescriptor<EarnedBadge>())
            badges.forEach { modelContext.delete($0) }

            let profiles = try modelContext.fetch(FetchDescriptor<PlayerProfile>())
            profiles.forEach { modelContext.delete($0) }

            try modelContext.save()
        } catch {
            print("[DataService] deleteAllUserData: SwiftData error: \(error)")
        }

        // 2. Delete session video files from Documents/Sessions/
        let sessionsDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory)

        if let contents = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil
        ) {
            contents.forEach { try? FileManager.default.removeItem(at: $0) }
        }

        // 3. Delete any exported JSON files written by ExportService to the temp directory.
        //    Pattern: hooptrack-export-<datestamp>.json
        let tmpDir = FileManager.default.temporaryDirectory
        if let tmpContents = try? FileManager.default.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil
        ) {
            tmpContents
                .filter { $0.lastPathComponent.hasPrefix("hooptrack-export-") && $0.pathExtension == "json" }
                .forEach { try? FileManager.default.removeItem(at: $0) }
        }

        // 4. Wipe Keychain
        KeychainService().deleteAll()

        // 5. Remove app-level UserDefaults keys
        let appDefaults: [String] = [
            "hasCompletedOnboarding",
            "preferredCameraPosition",
            "selectedDrillType",
            "onboardingPlayerName",
            "trainingReminderEnabled",
            "trainingReminderHour"
        ]
        appDefaults.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    // MARK: - Analytics Helpers

    /// FG% for the last `days` days.
    func fgPercent(lastDays days: Int) throws -> Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
        let predicate = #Predicate<TrainingSession> { $0.startedAt >= cutoff }
        let descriptor = FetchDescriptor(predicate: predicate)
        let sessions = try modelContext.fetch(descriptor)
        let attempted = sessions.reduce(0) { $0 + $1.shotsAttempted }
        let made      = sessions.reduce(0) { $0 + $1.shotsMade      }
        return attempted > 0 ? Double(made) / Double(attempted) * 100 : 0
    }

    /// Shot attempts per day for the last `days` days (for volume bar chart).
    func dailyVolume(lastDays days: Int) throws -> [(date: Date, attempts: Int)] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
        let predicate = #Predicate<TrainingSession> { $0.startedAt >= cutoff }
        let descriptor = FetchDescriptor(predicate: predicate)
        let sessions = try modelContext.fetch(descriptor)

        var byDay: [Date: Int] = [:]
        for session in sessions {
            let day = Calendar.current.startOfDay(for: session.startedAt)
            byDay[day, default: 0] += session.shotsAttempted
        }
        return byDay
            .map { (date: $0.key, attempts: $0.value) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Video Cleanup

    /// Deletes video files older than `days` days for sessions not pinned by the user.
    func purgeOldVideos(olderThanDays days: Int) throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
        let predicate = #Predicate<TrainingSession> {
            $0.startedAt < cutoff && !$0.videoPinnedByUser
        }
        let descriptor = FetchDescriptor(predicate: predicate)
        let stale = try modelContext.fetch(descriptor)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for session in stale {
            guard let filename = session.videoFileName else { continue }
            let url = docs
                .appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory)
                .appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
            session.videoFileName = nil
        }
        try modelContext.save()
    }

    // MARK: - Private Helpers

    private func updateProfileStats(_ profile: PlayerProfile, with session: TrainingSession) {
        profile.careerShotsAttempted += session.shotsAttempted
        profile.careerShotsMade      += session.shotsMade
        profile.totalSessionCount    += 1
        profile.totalTrainingMinutes += session.durationSeconds / 60

        // Personal Records
        if session.fgPercent > profile.prBestFGPercentSession {
            profile.prBestFGPercentSession = session.fgPercent
        }
        if session.shotsMade > profile.prMostMakesSession {
            profile.prMostMakesSession = session.shotsMade
        }
        if let score = session.consistencyScore,
           score < profile.prBestConsistencyScore {
            profile.prBestConsistencyScore = score
        }

        // Streak
        let today = Calendar.current.startOfDay(for: .now)
        if let lastDate = profile.lastSessionDate {
            let lastDay = Calendar.current.startOfDay(for: lastDate)
            let diff    = Calendar.current.dateComponents([.day], from: lastDay, to: today).day ?? 0
            if diff == 1 {
                profile.currentStreakDays += 1
            } else if diff > 1 {
                profile.currentStreakDays  = 1
            }
        } else {
            profile.currentStreakDays = 1
        }
        profile.longestStreakDays = max(profile.longestStreakDays, profile.currentStreakDays)
        profile.lastSessionDate   = .now
    }

}
