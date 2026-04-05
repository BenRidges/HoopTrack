// DataService.swift
// Abstraction layer over SwiftData (iOS 17+) / Core Data (iOS 16 fallback).
//
// All ViewModels interact with this service rather than directly with the
// ModelContext, keeping the data layer swappable without touching the UI.

import Foundation
import SwiftData
import Combine

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

    func startSession(drillType: DrillType,
                      namedDrill: NamedDrill? = nil,
                      courtType: CourtType = .nba,
                      locationTag: String = "") throws -> TrainingSession {
        let session = TrainingSession(drillType: drillType,
                                     namedDrill: namedDrill,
                                     courtType: courtType,
                                     locationTag: locationTag)
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
        session.endedAt         = .now
        session.durationSeconds = session.endedAt!.timeIntervalSince(session.startedAt)
        session.applyDribbleMetrics(metrics, durationSec: session.durationSeconds)
        try modelContext.save()

        let profile = try fetchOrCreateProfile()
        updateProfileStats(profile, with: session)
        updateBallHandlingRating(profile, from: session)
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

        // Apply Shot Science metrics if available
        if let s = science {
            shot.releaseAngleDeg = s.releaseAngleDeg
            shot.releaseTimeMs   = s.releaseTimeMs
            shot.verticalJumpCm  = s.verticalJumpCm
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
        if let courtX  = courtX  { shot.courtX  = courtX  }
        if let courtY  = courtY  { shot.courtY  = courtY  }
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
            let url = docs.appendingPathComponent("Sessions/\(filename)")
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

    private func updateBallHandlingRating(_ profile: PlayerProfile,
                                          from session: TrainingSession) {
        guard let bps = session.avgDribblesPerSec, bps > 0 else { return }
        // Scale: 3 BPS = 40 rating, 7 BPS = 90 rating. Clamp to 0–100.
        let raw = ((bps - HoopTrack.Dribble.optimalBPSMin)
                   / (HoopTrack.Dribble.optimalBPSMax - HoopTrack.Dribble.optimalBPSMin))
                  * 50.0 + 40.0
        let clamped = max(HoopTrack.SkillRating.minRating,
                          min(HoopTrack.SkillRating.maxRating, raw))
        // Exponential moving average (α = 0.3) so one session doesn't swing the rating wildly.
        let alpha = 0.3
        profile.ratingBallHandling = profile.ratingBallHandling == 0
            ? clamped
            : profile.ratingBallHandling * (1 - alpha) + clamped * alpha
    }
}
