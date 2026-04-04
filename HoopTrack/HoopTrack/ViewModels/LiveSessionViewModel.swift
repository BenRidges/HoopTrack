// LiveSessionViewModel.swift
// Owns all state for an active training session.
//
// Phase 1: Timer, manual shot logging, session lifecycle.
// Phase 2: Receive CV make/miss events from CVPipeline and call logShot().
// Phase 3: Receive ShotScience structs and attach to ShotRecord.
// Phase 4: Front camera + dribble metric events.

import Foundation
import Combine

@MainActor
final class LiveSessionViewModel: ObservableObject {

    // MARK: - Published
    @Published var session: TrainingSession?
    @Published var elapsedSeconds: Double = 0
    @Published var isPaused: Bool = false

    @Published var recentShots: [ShotRecord] = []   // last 5 shots for HUD strip
    @Published var lastShotResult: ShotResult?      // drives make/miss animation

    @Published var isSaving: Bool    = false
    @Published var isFinished: Bool  = false
    @Published var errorMessage: String?

    // MARK: - Phase 2 CV State
    @Published var calibrationIsActive: Bool = false
    @Published var isCalibrated: Bool = false

    // MARK: - Computed HUD Values
    var shotsAttempted: Int { session?.shotsAttempted ?? 0 }
    var shotsMade:      Int { session?.shotsMade ?? 0 }
    var fgPercent:      Double { session?.fgPercent ?? 0 }
    var fgPercentString: String { String(format: "%.0f%%", fgPercent) }

    // MARK: - Timer
    private var timerCancellable: AnyCancellable?
    private var sessionStartDate: Date?

    // MARK: - Dependencies
    private var dataService: DataService!
    private var hapticService: HapticService

    // Phase 2 — CV pipeline pending shot tracking
    private var pendingShotRecord: ShotRecord?

    /// No-arg init for use with SwiftUI @StateObject; call configure(dataService:hapticService:)
    /// before start() to inject the real dependencies from the view's environment.
    init() {
        self.hapticService = HapticService()
    }

    /// Preserved for unit tests.
    init(dataService: DataService, hapticService: HapticService) {
        self.dataService   = dataService
        self.hapticService = hapticService
    }

    func configure(dataService: DataService, hapticService: HapticService) {
        self.dataService   = dataService
        self.hapticService = hapticService
    }

    // MARK: - Lifecycle

    func start(drillType: DrillType,
               namedDrill: NamedDrill? = nil,
               courtType: CourtType = .nba,
               locationTag: String = "") {
        do {
            session = try dataService.startSession(drillType: drillType,
                                                   namedDrill: namedDrill,
                                                   courtType: courtType,
                                                   locationTag: locationTag)
            sessionStartDate = .now
            startTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pause() {
        isPaused = true
        timerCancellable?.cancel()
    }

    func resume() {
        isPaused = false
        startTimer()
    }

    func endSession() {
        guard let session else { return }
        isSaving = true
        timerCancellable?.cancel()

        do {
            try dataService.finaliseSession(session)
            isFinished = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: - Shot Logging

    /// Called by CV pipeline (Phase 2) or manual tap for testing (Phase 1).
    func logShot(result: ShotResult,
                 zone: CourtZone = .unknown,
                 shotType: ShotType = .unknown,
                 courtX: Double = 0.5,
                 courtY: Double = 0.5) {
        guard let session else { return }
        do {
            let shot = try dataService.addShot(to: session,
                                               result: result,
                                               zone: zone,
                                               shotType: shotType,
                                               courtX: courtX,
                                               courtY: courtY)
            recentShots = Array(session.shots.suffix(5))
            lastShotResult = result
            triggerHaptic(for: result)
            _ = shot  // Future: attach Shot Science metadata here (Phase 3)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Phase 2 CV Shot Logging

    /// Called by CVPipeline when the ball peaks (release detected).
    /// Creates a pending ShotRecord and stores a reference for later resolution.
    func logPendingShot(zone: CourtZone,
                        courtX: Double,
                        courtY: Double,
                        science: ShotScienceMetrics? = nil) {
        guard let session else { return }
        do {
            let shot = try dataService.addShot(to: session,
                                               result: .pending,
                                               zone: zone,
                                               shotType: .unknown,
                                               courtX: courtX,
                                               courtY: courtY,
                                               science: science)
            pendingShotRecord = shot
            recentShots       = Array(session.shots.suffix(5))
            lastShotResult    = .pending
            triggerHaptic(for: .pending)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Called by CVPipeline when make/miss is determined.
    /// Updates the pending ShotRecord in place; falls back to a fresh logShot if
    /// no pending record exists (guards against edge-case timing).
    func resolvePendingShot(result: ShotResult, zone: CourtZone, courtX: Double, courtY: Double) {
        guard let pending = pendingShotRecord else {
            logShot(result: result, zone: zone, courtX: courtX, courtY: courtY)
            return
        }
        do {
            try dataService.resolveShot(pending,
                                        result: result,
                                        zone: zone,
                                        courtX: courtX,
                                        courtY: courtY)
            pendingShotRecord = nil
            recentShots       = Array(session?.shots.suffix(5) ?? [])
            lastShotResult    = result
            triggerHaptic(for: result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Called by LiveSessionView when CourtCalibrationService changes state.
    func updateCalibrationState(isCalibrated: Bool) {
        self.isCalibrated        = isCalibrated
        self.calibrationIsActive = isCalibrated
    }

    // MARK: - Timer (private)

    private func startTimer() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, !self.isPaused else { return }
                self.elapsedSeconds += 1
            }
    }

    var elapsedFormatted: String {
        let mins = Int(elapsedSeconds) / 60
        let secs = Int(elapsedSeconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Haptics (private)

    private func triggerHaptic(for result: ShotResult) {
        switch result {
        case .make:    hapticService.makeMade()
        case .miss:    hapticService.missMade()
        case .pending: hapticService.shotDetected()
        }
    }
}
