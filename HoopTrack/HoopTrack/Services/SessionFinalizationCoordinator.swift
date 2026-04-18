// SessionFinalizationCoordinator.swift
// Sequences the 7-step finalisation pipeline after every session ends.
// Holds protocol references only — concrete types injected at app startup.

import Foundation
import Combine

@MainActor final class SessionFinalizationCoordinator: ObservableObject {

    let objectWillChange = ObservableObjectPublisher()

    private let dataService:            DataService
    private let goalUpdateService:      GoalUpdateServiceProtocol
    private let healthKitService:       HealthKitServiceProtocol
    private let skillRatingService:     SkillRatingServiceProtocol
    private let badgeEvaluationService: BadgeEvaluationServiceProtocol
    private let notificationService:    NotificationService

    init(
        dataService:            DataService,
        goalUpdateService:      GoalUpdateServiceProtocol,
        healthKitService:       HealthKitServiceProtocol,
        skillRatingService:     SkillRatingServiceProtocol,
        badgeEvaluationService: BadgeEvaluationServiceProtocol,
        notificationService:    NotificationService
    ) {
        self.dataService            = dataService
        self.goalUpdateService      = goalUpdateService
        self.healthKitService       = healthKitService
        self.skillRatingService     = skillRatingService
        self.badgeEvaluationService = badgeEvaluationService
        self.notificationService    = notificationService
    }

    // MARK: - HealthKit permission

    func requestHealthKitPermission() async {
        await healthKitService.requestPermission()
    }

    // MARK: - Finalisation entry points

    /// Standard shooting session.
    func finaliseSession(_ session: TrainingSession) async throws -> SessionResult {
        let profile = try dataService.fetchOrCreateProfile()
        // 1. Stamp endedAt, recalculate stats, persist
        try dataService.finaliseSession(session)
        // 2. Update goal currentValues + isAchieved
        try goalUpdateService.update(after: session, profile: profile)
        // 3. Write HealthKit workout (async, silent failure)
        try? await healthKitService.writeWorkout(for: session)
        // 4. EMA-update all 5 skill dimension ratings
        try skillRatingService.recalculate(for: profile, session: session)
        // 5. Badge MMR delta — skip for shooting sessions under the minimum shot threshold
        let badgeSkipReason = Self.badgeSkipReason(drillType: session.drillType,
                                                   shotsAttempted: session.shotsAttempted)
        let badgeChanges: [BadgeTierChange]
        if badgeSkipReason != nil {
            badgeChanges = []
        } else {
            badgeChanges = (try? badgeEvaluationService.evaluate(session: session, profile: profile)) ?? []
        }
        // 6. Fire milestone notifications for newly crossed thresholds
        notificationService.checkMilestones(for: profile.goals)
        // 7. Return result for ViewModel to display
        return SessionResult(session: session, badgeChanges: badgeChanges, badgeSkipReason: badgeSkipReason)
    }

    /// Pure decision: returns a skip reason when badge evaluation should be bypassed for
    /// this session, or nil when evaluation should run. Currently gates only shooting
    /// sessions by shot count — dribble and agility drills always evaluate.
    nonisolated static func badgeSkipReason(drillType: DrillType,
                                             shotsAttempted: Int) -> String? {
        let minShots = HoopTrack.SkillRating.badgeMinShotsForShootingSession
        guard drillType == .freeShoot, shotsAttempted < minShots else { return nil }
        return "Shoot at least \(minShots) shots to update badges."
    }

    /// Dribble drill session.
    func finaliseDribbleSession(_ session: TrainingSession,
                                 metrics: DribbleLiveMetrics) async throws -> SessionResult {
        let profile = try dataService.fetchOrCreateProfile()
        try dataService.finaliseDribbleSession(session, metrics: metrics)
        try goalUpdateService.update(after: session, profile: profile)
        try? await healthKitService.writeWorkout(for: session)
        try skillRatingService.recalculate(for: profile, session: session)
        let badgeChanges = (try? badgeEvaluationService.evaluate(session: session, profile: profile)) ?? []
        notificationService.checkMilestones(for: profile.goals)
        return SessionResult(session: session, badgeChanges: badgeChanges)
    }

    /// Agility session — caller provides best times measured during the session.
    func finaliseAgilitySession(_ session: TrainingSession,
                                 attempts: AgilityAttempts) async throws -> SessionResult {
        session.bestShuttleRunSeconds  = attempts.bestShuttleRunSeconds
        session.bestLaneAgilitySeconds = attempts.bestLaneAgilitySeconds
        let profile = try dataService.fetchOrCreateProfile()
        try dataService.finaliseSession(session)
        try goalUpdateService.update(after: session, profile: profile)
        try? await healthKitService.writeWorkout(for: session)
        try skillRatingService.recalculate(for: profile, session: session)
        let badgeChanges = (try? badgeEvaluationService.evaluate(session: session, profile: profile)) ?? []
        notificationService.checkMilestones(for: profile.goals)
        return SessionResult(session: session, badgeChanges: badgeChanges)
    }
}
