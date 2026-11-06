// DataService.swift
// The single SwiftData abstraction. Views and view models go through this
// rather than touching ModelContext directly. One instance, created at
// launch by AppServices and injected through the environment.

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

    let modelContext: ModelContext

    /// Bumped after any write that changes what the dashboards show, so
    /// screens can reload without polling.
    @Published private(set) var revision = 0

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Player Profile

    /// Returns the single PlayerProfile, creating one if it doesn't exist.
    func fetchOrCreateProfile() throws -> PlayerProfile {
        var descriptor = FetchDescriptor<PlayerProfile>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first { return existing }

        let profile = PlayerProfile()
        modelContext.insert(profile)
        try modelContext.save()
        return profile
    }

    func setPlayerName(_ raw: String) {
        // Phase 7 — Security: sanitise before writing to SwiftData.
        guard let name = InputValidator.sanitisedProfileName(raw),
              let profile = try? fetchOrCreateProfile() else { return }
        profile.name = name
        save()
    }

    /// Associates the profile with a Supabase user id. No-op if unchanged.
    func linkSupabaseUser(id: String) throws {
        let profile = try fetchOrCreateProfile()
        if profile.supabaseUserID != id {
            profile.supabaseUserID = id
            try modelContext.save()
        }
    }

    func unlinkSupabaseUser() {
        guard let profile = try? fetchOrCreateProfile(), profile.supabaseUserID != nil else { return }
        profile.supabaseUserID = nil
        save()
    }

    // MARK: - Sessions

    func fetchSessions(sortBy: SortDescriptor<TrainingSession> =
                           SortDescriptor(\.startedAt, order: .reverse),
                       limit: Int? = nil) throws -> [TrainingSession] {
        var descriptor = FetchDescriptor<TrainingSession>(
            predicate: #Predicate { $0.endedAt != nil },
            sortBy: [sortBy])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

    /// Completed sessions that started on or after `date`, most recent first.
    func fetchSessions(since date: Date, limit: Int? = nil) throws -> [TrainingSession] {
        var descriptor = FetchDescriptor<TrainingSession>(
            predicate: #Predicate { $0.startedAt >= date && $0.endedAt != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

    /// Whether any session has been completed today (reminder scheduling).
    var hasTrainedToday: Bool {
        !((try? fetchSessions(since: Calendar.current.startOfDay(for: .now), limit: 1)) ?? []).isEmpty
    }

    /// Total shots attempted across sessions that started today (Siri).
    func fetchShotsTodayCount() throws -> Int {
        try fetchSessions(since: Calendar.current.startOfDay(for: .now))
            .reduce(0) { $0 + $1.shotsAttempted }
    }

    func startSession(drillType: DrillType,
                      namedDrill: NamedDrill? = nil,
                      courtType: CourtType = .nba,
                      locationTag: String = "",
                      playoffSeriesID: UUID? = nil) throws -> TrainingSession {
        // Phase 7 — Security: sanitise free-text location tag before persisting.
        let safeTag = String(locationTag.unicodeScalars
            .filter { !CharacterSet.controlCharacters.union(.illegalCharacters).contains($0) }
            .map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(100))
        let session = TrainingSession(drillType: drillType,
                                      namedDrill: namedDrill,
                                      courtType: courtType,
                                      locationTag: safeTag)
        session.playoffSeriesID = playoffSeriesID
        let profile = try fetchOrCreateProfile()
        session.profile = profile
        modelContext.insert(session)
        try modelContext.save()
        return session
    }

    /// Stamps the end of a shooting/agility session and folds it into career stats.
    /// - Parameter activeDuration: time actually spent training (pauses excluded).
    ///   Defaults to wall-clock time since the session started.
    func finaliseSession(_ session: TrainingSession, activeDuration: TimeInterval? = nil) throws {
        let now = Date.now
        session.endedAt         = now
        session.durationSeconds = activeDuration ?? now.timeIntervalSince(session.startedAt)
        // An unresolved in-flight shot when the session ends is noise.
        let pending = session.shots.filter { $0.result == .pending }
        session.shots.removeAll { $0.result == .pending }
        pending.forEach(modelContext.delete)
        session.recalculateStats()
        try modelContext.save()
        try recomputeCareerStats()
    }

    /// Finalises a dribble session with the live metrics from the pipeline.
    func finaliseDribbleSession(_ session: TrainingSession,
                                metrics: DribbleLiveMetrics,
                                activeDuration: TimeInterval? = nil) throws {
        let now = Date.now
        session.endedAt         = now
        session.durationSeconds = activeDuration ?? now.timeIntervalSince(session.startedAt)
        session.applyDribbleMetrics(metrics, durationSec: session.durationSeconds)
        try modelContext.save()
        try recomputeCareerStats()
    }

    /// Throws away a session that was started but never meaningfully used.
    func discardSession(_ session: TrainingSession) {
        modelContext.delete(session)
        save()
    }

    func deleteSession(_ session: TrainingSession) throws {
        if let file = session.videoFileName {
            try? FileManager.default.removeItem(at: SessionRecorder.directory.appendingPathComponent(file))
        }
        let playoff = session.playoffSeriesID
        modelContext.delete(session)
        try modelContext.save()
        try recomputeCareerStats()
        refreshPlayoff(taggedOn: playoff)
    }

    // MARK: - Shots

    @discardableResult
    func addShot(to session: TrainingSession,
                 result: ShotResult,
                 zone: CourtZone,
                 shotType: ShotType,
                 courtX: Double,
                 courtY: Double,
                 science: ShotScienceMetrics? = nil,
                 videoOffset: Double? = nil,
                 needsReview: Bool = false,
                 detectionConfidence: Double? = nil) throws -> ShotRecord {
        // Phase 7 — Security: validate sensor inputs before persistence.
        guard InputValidator.isValidCourtCoordinate(courtX),
              InputValidator.isValidCourtCoordinate(courtY) else {
            throw DataServiceError.invalidSensorValue("Court coordinates out of 0–1 range: (\(courtX), \(courtY))")
        }

        let nextIndex = (session.shots.map(\.sequenceIndex).max() ?? 0) + 1
        let shot = ShotRecord(sequenceIndex: nextIndex,
                              result: result,
                              zone: zone,
                              shotType: shotType,
                              courtX: courtX,
                              courtY: courtY)
        shot.videoTimestampSeconds = videoOffset ?? shot.timestamp.timeIntervalSince(session.startedAt)
        shot.needsReview = needsReview
        shot.detectionConfidence = detectionConfidence
        apply(science, to: shot)

        modelContext.insert(shot)
        shot.session = session
        session.shots.append(shot)
        session.recalculateStats()
        try modelContext.save()
        return shot
    }

    /// User correction from the summary or the live HUD.
    /// Sets a shot's result. Passing the current result just confirms a
    /// flagged call: the flag clears but the shot isn't marked as edited.
    func updateShot(_ shot: ShotRecord, result: ShotResult) {
        guard shot.result != result || shot.needsReview else { return }
        if shot.result != result {
            shot.result = result
            shot.isUserCorrected = true
            // Back up the correction (and the session's new totals).
            shot.cloudSyncedAt = nil
            shot.session?.cloudSyncedAt = nil
        }
        shot.needsReview = false
        shot.session?.recalculateStats()
        save()
        refreshCareerStatsIfFinished(shot.session)
        refreshPlayoff(taggedOn: shot.session?.playoffSeriesID)
    }

    /// Removes a shot that never happened (live "undo" or summary delete).
    func deleteShot(_ shot: ShotRecord) {
        let session = shot.session
        session?.shots.removeAll { $0.id == shot.id }
        session?.cloudSyncedAt = nil
        modelContext.delete(shot)
        session?.recalculateStats()
        save()
        refreshCareerStatsIfFinished(session)
        refreshPlayoff(taggedOn: session?.playoffSeriesID)
    }

    // MARK: - Goals

    func addGoal(_ goal: GoalRecord, to profile: PlayerProfile) throws {
        modelContext.insert(goal)
        goal.profile = profile
        profile.goals.append(goal)
        try modelContext.save()
        revision += 1
    }

    func deleteGoal(_ goal: GoalRecord) throws {
        modelContext.delete(goal)
        try modelContext.save()
        revision += 1
    }

    // MARK: - Analytics Helpers

    /// FG% across shooting sessions in the last `days` days.
    func fgPercent(lastDays days: Int) throws -> Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        let sessions = try fetchSessions(since: cutoff)
        let attempted = sessions.reduce(0) { $0 + $1.shotsAttempted }
        let made      = sessions.reduce(0) { $0 + $1.shotsMade }
        return attempted > 0 ? Double(made) / Double(attempted) * 100 : 0
    }

    /// Shot attempts per calendar day for the last `days` days, oldest first,
    /// including zero days so charts keep a steady x-axis.
    func dailyVolume(lastDays days: Int) throws -> [(date: Date, attempts: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var byDay: [Date: Int] = [:]
        for session in try fetchSessions(since: first) {
            byDay[calendar.startOfDay(for: session.startedAt), default: 0] += session.shotsAttempted
        }
        return (0..<days).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: first).map { ($0, byDay[$0] ?? 0) }
        }
    }

    // MARK: - Career stats

    /// Rebuilds career totals, records and streaks from the sessions on
    /// disk. Running totals drifted whenever a session was deleted or a shot
    /// corrected; recomputing keeps them honest.
    func recomputeCareerStats() throws {
        let profile = try fetchOrCreateProfile()
        let sessions = try fetchSessions()

        profile.careerShotsAttempted = sessions.reduce(0) { $0 + $1.shotsAttempted }
        profile.careerShotsMade      = sessions.reduce(0) { $0 + $1.shotsMade }
        profile.totalSessionCount    = sessions.count
        profile.totalTrainingMinutes = sessions.reduce(0) { $0 + $1.durationSeconds } / 60

        let shooting = sessions.filter { $0.shotsAttempted >= 10 }
        profile.prBestFGPercentSession = shooting.map(\.fgPercent).max() ?? 0
        profile.prMostMakesSession     = sessions.map(\.shotsMade).max() ?? 0
        profile.prBestConsistencyScore = sessions.compactMap(\.consistencyScore).min() ?? .infinity

        let days = sessions.map(\.startedAt)
        profile.currentStreakDays = StreakCalculator.current(trainingDays: days)
        profile.longestStreakDays = StreakCalculator.longest(trainingDays: days)
        profile.lastSessionDate   = sessions.first?.startedAt
        try modelContext.save()
        revision += 1
    }

    // MARK: - Video Cleanup

    /// Deletes videos older than `days` days unless pinned.
    func purgeOldVideos(olderThanDays days: Int) throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        let directory = SessionRecorder.directory

        let staleTraining = try modelContext.fetch(FetchDescriptor<TrainingSession>(
            predicate: #Predicate { $0.startedAt < cutoff && !$0.videoPinnedByUser }))
        for session in staleTraining {
            guard let filename = session.videoFileName else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
            session.videoFileName = nil
        }

        // Phase 10 — game sessions follow the same retention policy.
        let staleGames = try modelContext.fetch(FetchDescriptor<GameSession>(
            predicate: #Predicate { $0.startTimestamp < cutoff && !$0.videoPinnedByUser }))
        for game in staleGames {
            guard let filename = game.videoFileName else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
            game.videoFileName = nil
        }
        try modelContext.save()
    }

    // MARK: - Game Mode

    /// Logs a scorekeeper shot and updates the team score.
    func addGameShot(to game: GameSession,
                     shooter: GamePlayer?,
                     result: ShotResult,
                     courtX: Double = 0.5,
                     courtY: Double = 0.5,
                     shotType: GameShotType,
                     attributionConfidence: Double = 1.0) throws {
        guard InputValidator.isValidCourtCoordinate(courtX),
              InputValidator.isValidCourtCoordinate(courtY) else {
            throw DataServiceError.invalidSensorValue("court coordinate out of range")
        }
        let shot = GameShotRecord(shooter: shooter,
                                  result: result,
                                  courtX: courtX, courtY: courtY,
                                  shotType: shotType,
                                  attributionConfidence: attributionConfidence)
        modelContext.insert(shot)
        game.shots.append(shot)
        if result == .make { adjustScore(of: game, for: shot, by: 1) }
        try modelContext.save()
    }

    /// Removes the most recent shot from a game, reversing its points.
    func undoLastGameShot(in game: GameSession) {
        guard let last = game.shots.max(by: { $0.timestamp < $1.timestamp }) else { return }
        if last.result == .make { adjustScore(of: game, for: last, by: -1) }
        game.shots.removeAll { $0.id == last.id }
        modelContext.delete(last)
        save()
    }

    func endGame(_ game: GameSession) {
        game.gameState = .completed
        game.endTimestamp = .now
        save()
        revision += 1
    }

    // MARK: - Playoffs

    /// The run in progress, if any. Starting a new one ends the old, so
    /// there's at most one.
    func activePlayoffSeries() -> PlayoffSeries? {
        let descriptor = FetchDescriptor<PlayoffSeries>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? modelContext.fetch(descriptor))?.first { $0.isActive }
    }

    func playoffSeries(id: UUID) -> PlayoffSeries? {
        var descriptor = FetchDescriptor<PlayoffSeries>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    func startPlayoffSeries(spot: PlayoffSpot) throws -> PlayoffSeries {
        if let current = activePlayoffSeries() { retirePlayoff(current) }
        let series = PlayoffSeries(spot: spot)
        modelContext.insert(series)
        try modelContext.save()
        revision += 1
        return series
    }

    /// The run, replayed from every shot of its sessions in order.
    func playoffRun(for series: PlayoffSeries) -> PlayoffRun {
        let target: UUID? = series.id
        let descriptor = FetchDescriptor<TrainingSession>(
            predicate: #Predicate { $0.playoffSeriesID == target },
            sortBy: [SortDescriptor(\.startedAt)])
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        var run = PlayoffRun(spot: series.spot,
                             results: sessions.flatMap { $0.orderedShots.map(\.result) })
        if series.retiredAt != nil { run.retire() }
        return run
    }

    /// Re-reads the run into the series' cached numbers.
    func refreshPlayoff(_ series: PlayoffSeries) {
        let run = playoffRun(for: series)
        series.round       = run.round
        series.wins        = run.wins
        series.losses      = run.losses
        series.status      = run.status
        series.gamesPlayed = run.games.count
        series.updatedAt   = .now
        if run.status == .champion, series.wonAt == nil { series.wonAt = .now }
        save()
        revision += 1
    }

    /// Ends a run early. Its sessions and shots stay in history.
    func retirePlayoff(_ series: PlayoffSeries) {
        guard series.isActive else { return }
        series.retiredAt = .now
        series.status = .retired
        series.updatedAt = .now
        save()
        revision += 1
    }

    /// Shots this player has taken, for the comeback drill's weak-spot hint.
    func recentShotZones(limit: Int = 600) -> [(zone: CourtZone, made: Bool)] {
        var descriptor = FetchDescriptor<ShotRecord>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map { ($0.zone, $0.result == .make) }
    }

    private func refreshPlayoff(taggedOn seriesID: UUID?) {
        guard let seriesID, let series = playoffSeries(id: seriesID) else { return }
        refreshPlayoff(series)
    }

    // MARK: - Delete everything (Phase 7 — GDPR right-to-delete)

    /// Permanently removes all user data: SwiftData records, session videos,
    /// telemetry, exported files, Keychain entries and app preferences.
    func deleteAllUserData() async {
        do {
            // Children before parents, one object at a time — SwiftData's
            // batch delete is unreliable across relationships.
            try deleteEvery(ShotRecord.self)
            try deleteEvery(TrainingSession.self)
            try deleteEvery(GoalRecord.self)
            try deleteEvery(EarnedBadge.self)
            try deleteEvery(GameShotRecord.self)
            try deleteEvery(GamePlayer.self)
            try deleteEvery(GameSession.self)
            try deleteEvery(TelemetryUpload.self)
            try deleteEvery(PlayoffSeries.self)
            try deleteEvery(PlayerProfile.self)
            try modelContext.save()
        } catch {
            print("[DataService] deleteAllUserData: SwiftData error: \(error)")
        }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for folder in [HoopTrack.Storage.sessionVideoDirectory, HoopTrack.Telemetry.telemetryDirectoryName] {
            let dir = docs.appendingPathComponent(folder)
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: url)
            }
        }

        // Exported JSON files: hooptrack-export-<datestamp>.json in tmp.
        for url in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("hooptrack-export-") && url.pathExtension == "json" {
            try? fm.removeItem(at: url)
        }

        KeychainService().deleteAll()
        AppPreferences.removeAll()
        revision += 1
    }

    // MARK: - Private

    private func apply(_ science: ShotScienceMetrics?, to shot: ShotRecord) {
        guard let science else { return }
        // Phase 7 — Security: validate ranges before persisting.
        if let angle = science.releaseAngleDeg, InputValidator.isValidReleaseAngle(angle) {
            shot.releaseAngleDeg = angle
        }
        if let jump = science.verticalJumpCm, InputValidator.isValidJumpHeight(jump) {
            shot.verticalJumpCm = jump
        }
        if let speed = science.shotSpeedMph, speed.isFinite, (5...60).contains(speed) {
            shot.shotSpeedMph = speed
        }
        shot.releaseTimeMs = science.releaseTimeMs
        shot.legAngleDeg   = science.legAngleDeg
    }

    private func deleteEvery<T: PersistentModel>(_ type: T.Type) throws {
        for object in try modelContext.fetch(FetchDescriptor<T>()) {
            modelContext.delete(object)
        }
    }

    private func adjustScore(of game: GameSession, for shot: GameShotRecord, by sign: Int) {
        let points = (shot.shotType == .threePoint ? 3 : 2) * sign
        switch shot.shooter?.teamAssignment {
        case .teamA: game.teamAScore = max(0, game.teamAScore + points)
        case .teamB: game.teamBScore = max(0, game.teamBScore + points)
        case .none:  break   // unattributed — no team credit
        }
    }

    private func refreshCareerStatsIfFinished(_ session: TrainingSession?) {
        guard session?.isComplete == true else { return }
        try? recomputeCareerStats()
    }

    private func save() {
        do { try modelContext.save() } catch {
            print("[DataService] save failed: \(error)")
        }
    }
}
