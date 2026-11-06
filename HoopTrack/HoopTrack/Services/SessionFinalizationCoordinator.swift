// SessionFinalizationCoordinator.swift
// Runs the post-session pipeline after every session ends:
//   1. stamp end + duration, recompute stats and career totals
//   2. goal progress
//   3. Apple Health workout (opt-in)
//   4. skill ratings (EMA)
//   5. badge MMR
//   6. goal milestone notifications
//   7. Supabase sync (signed-in users, fire-and-forget)
//   8. CV-A telemetry capture + upload (opt-in, fire-and-forget)

import Foundation
import SwiftData
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

    // MARK: - HealthKit permission

    /// Called when the user turns on "Save to Apple Health".
    func requestHealthKitPermission() async {
        await healthKitService.requestPermission()
    }

    // MARK: - Finalisation entry points

    /// Shooting session.
    func finaliseSession(_ session: TrainingSession,
                         activeDuration: TimeInterval? = nil) async throws -> SessionResult {
        try dataService.finaliseSession(session, activeDuration: activeDuration)
        let skipReason = Self.badgeSkipReason(drillType: session.drillType,
                                              shotsAttempted: session.shotsAttempted)
        return try await runPipeline(for: session, evaluateBadges: skipReason == nil, skipReason: skipReason)
    }

    /// Dribble drill session.
    func finaliseDribbleSession(_ session: TrainingSession,
                                metrics: DribbleLiveMetrics,
                                activeDuration: TimeInterval? = nil) async throws -> SessionResult {
        try dataService.finaliseDribbleSession(session, metrics: metrics, activeDuration: activeDuration)
        return try await runPipeline(for: session, evaluateBadges: true, skipReason: nil)
    }

    /// Agility session — best times measured during the session.
    func finaliseAgilitySession(_ session: TrainingSession,
                                attempts: AgilityAttempts,
                                activeDuration: TimeInterval? = nil) async throws -> SessionResult {
        session.bestShuttleRunSeconds  = attempts.bestShuttleRunSeconds
        session.bestLaneAgilitySeconds = attempts.bestLaneAgilitySeconds
        try dataService.finaliseSession(session, activeDuration: activeDuration)
        return try await runPipeline(for: session, evaluateBadges: true, skipReason: nil)
    }

    /// Pure decision: a skip reason when badge evaluation should be bypassed,
    /// nil when it should run. Only shooting sessions are gated, by shot count.
    nonisolated static func badgeSkipReason(drillType: DrillType,
                                            shotsAttempted: Int) -> String? {
        let minShots = HoopTrack.SkillRating.badgeMinShotsForShootingSession
        guard drillType == .freeShoot, shotsAttempted < minShots else { return nil }
        return "Shoot at least \(minShots) shots to move your badges."
    }

    // MARK: - Shared pipeline

    private func runPipeline(for session: TrainingSession,
                             evaluateBadges: Bool,
                             skipReason: String?) async throws -> SessionResult {
        let profile = try dataService.fetchOrCreateProfile()
        try goalUpdateService.update(after: session, profile: profile)
        if AppPreferences.healthKitEnabled {
            try? await healthKitService.writeWorkout(for: session)
        }
        try skillRatingService.recalculate(for: profile, session: session)
        let badgeChanges = evaluateBadges
            ? (try? badgeEvaluationService.evaluate(session: session, profile: profile)) ?? []
            : []
        notificationService.checkMilestones(for: profile.goals)
        notificationService.refreshTrainingReminders(trainedToday: true)
        kickOffSync(session: session, profile: profile)
        kickOffTelemetry(session: session, profile: profile)
        return SessionResult(session: session, badgeChanges: badgeChanges, badgeSkipReason: skipReason)
    }

    /// Fire-and-forget Supabase upload. Skips when signed out or for trivial
    /// sessions. Failure is silent — the local save already succeeded.
    private func kickOffSync(session: TrainingSession, profile: PlayerProfile) {
        guard let syncCoordinator,
              let uidString = profile.supabaseUserID,
              let userID = UUID(uuidString: uidString),
              session.endedAt != nil, session.durationSeconds >= 30 else { return }
        Task { @MainActor [syncCoordinator, dataService] in
            try? await syncCoordinator.syncSession(session, userID: userID)
            try? dataService.modelContext.save()
        }
    }

    /// CV-A telemetry. Strictly opt-in; also needs a recorded video and a
    /// signed-in account to upload to.
    private func kickOffTelemetry(session: TrainingSession, profile: PlayerProfile) {
        guard AppPreferences.shareTrainingData,
              let capture = telemetryCaptureService,
              let upload = telemetryUploadService,
              let videoFileName = session.videoFileName,
              session.durationSeconds >= HoopTrack.Telemetry.minSessionDurationSec,
              let uidString = profile.supabaseUserID,
              let userID = UUID(uuidString: uidString)
        else { return }

        let videoURL = SessionRecorder.directory.appendingPathComponent(videoFileName)
        let shotTimestamps = session.orderedShots.compactMap(\.videoTimestampSeconds)
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
}
