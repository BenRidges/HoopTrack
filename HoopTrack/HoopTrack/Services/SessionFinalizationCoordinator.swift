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
    private let syncCoordinator:        SyncCoordinator?
    private let telemetryCaptureService: TelemetryCaptureService?
    private let telemetryUploadService:  TelemetryUploadService?

    init(
        dataService:            DataService,
        goalUpdateService:      GoalUpdateServiceProtocol,
        healthKitService:       HealthKitServiceProtocol,
        skillRatingService:     SkillRatingServiceProtocol,
        badgeEvaluationService: BadgeEvaluationServiceProtocol,
        notificationService:    NotificationService,
        syncCoordinator:        SyncCoordinator? = nil,
        telemetryCaptureService: TelemetryCaptureService? = nil,
        telemetryUploadService:  TelemetryUploadService? = nil
    ) {
        self.dataService            = dataService
        self.goalUpdateService      = goalUpdateService
        self.healthKitService       = healthKitService
        self.skillRatingService     = skillRatingService
        self.badgeEvaluationService = badgeEvaluationService
        self.notificationService    = notificationService
        self.syncCoordinator        = syncCoordinator
        self.telemetryCaptureService = telemetryCaptureService
        self.telemetryUploadService  = telemetryUploadService
    }

    /// Fire-and-forget Supabase upload. Skips if:
    /// - No coordinator wired (tests, uninjected contexts).
    /// - No supabaseUserID on the profile (user is signed out).
    /// - Session is too trivial to be interesting (< 30s or no endedAt).
    /// Failure is silent — the local save already succeeded.
    private func kickOffSync(session: TrainingSession, profile: PlayerProfile) {
        guard let syncCoordinator else { return }
        guard let uidString = profile.supabaseUserID,
              let userID = UUID(uuidString: uidString) else { return }
        guard session.endedAt != nil, session.durationSeconds >= 30 else { return }
        Task { @MainActor [syncCoordinator] in
            try? await syncCoordinator.syncSession(session, userID: userID)
        }
    }

    /// Step 10 — CV-A Telemetry Capture & Upload.
    /// Fire-and-forget: runs after sync so it never blocks session summary.
    /// Skips silently if any prerequisite is missing (no video, no user,
    /// no services wired, session too short).
    private func kickOffTelemetry(session: TrainingSession, profile: PlayerProfile) {
        guard let capture = telemetryCaptureService,
              let upload = telemetryUploadService,
              let videoFileName = session.videoFileName,
              session.durationSeconds >= HoopTrack.Telemetry.minSessionDurationSec,
              let uidString = profile.supabaseUserID,
              let userID = UUID(uuidString: uidString)
        else { return }

        let videoURL = Self.sessionVideoURL(filename: videoFileName)
        let shotTimestamps = session.shots.map { $0.timestamp.timeIntervalSince(session.startedAt) }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let sessionID = session.id
        let sessionStartedAt = session.startedAt
        let durationSec = session.durationSeconds

        Task { @MainActor in
            let result = await capture.capture(
                sessionID: sessionID,
                sessionKind: .training,
                videoURL: videoURL,
                shotTimestamps: shotTimestamps,
                sessionStartedAt: sessionStartedAt,
                sessionDurationSec: durationSec,
                modelVersion: HoopTrack.MLModel.modelVersion,
                appVersion: appVersion
            )
            if result != nil {
                await upload.uploadPending(userID: userID)
            }
        }
    }

    private static func sessionVideoURL(filename: String) -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory)
            .appendingPathComponent(filename)
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
        // 7. Fire-and-forget Supabase sync — non-fatal if offline
        kickOffSync(session: session, profile: profile)
        // 8. CV-A — fire-and-forget telemetry capture + upload
        kickOffTelemetry(session: session, profile: profile)
        // 9. Return result for ViewModel to display
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
        kickOffSync(session: session, profile: profile)
        kickOffTelemetry(session: session, profile: profile)
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
        kickOffSync(session: session, profile: profile)
        kickOffTelemetry(session: session, profile: profile)
        return SessionResult(session: session, badgeChanges: badgeChanges)
    }
}
