// LiveSessionViewModel.swift
// Owns all state for an active training session.
//
// Phase 1: Timer, manual shot logging, session lifecycle.
// Phase 2: Receive CV make/miss events from CVPipeline and call logShot().
// Phase 3: Receive ShotScience structs and attach to ShotRecord.
// Phase 4: Front camera + dribble metric events.

import Foundation
import Combine
import UIKit

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

    // MARK: - Detection Overlay State
    // Vision-normalised rects (origin bottom-left, 0–1). The overlay view
    // flips to SwiftUI's top-left origin when drawing.
    @Published var detectedHoopRect: CGRect?
    @Published var detectedBallBox: CGRect?
    @Published var detectedBallConfidence: Float?

    // MARK: - Computed HUD Values
    var shotsAttempted: Int { session?.shotsAttempted ?? 0 }
    var shotsMade:      Int { session?.shotsMade ?? 0 }
    var fgPercent:      Double { session?.fgPercent ?? 0 }
    var fgPercentString: String { String(format: "%.0f%%", fgPercent) }

    // MARK: - Timer
    private var timerCancellable: AnyCancellable?
    private var sessionStartDate: Date?

    // MARK: - Accessibility
    private var lastAnnouncementDate: Date = .distantPast

    // MARK: - Dependencies
    @Published var sessionResult: SessionResult?

    private var dataService: DataService!
    private var hapticService: HapticService
    private var coordinator: SessionFinalizationCoordinator!

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

    func configure(dataService: DataService,
                   hapticService: HapticService,
                   coordinator: SessionFinalizationCoordinator) {
        self.dataService   = dataService
        self.hapticService = hapticService
        self.coordinator   = coordinator
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

    func endSession() async {
        guard let session else { return }
        isSaving = true
        timerCancellable?.cancel()
        do {
            sessionResult = try await coordinator.finaliseSession(session)
            isFinished    = true
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
        // Phase 7 — Security: clamp coordinates to valid half-court range
        let safeX = InputValidator.isValidCourtCoordinate(courtX) ? courtX : 0.5
        let safeY = InputValidator.isValidCourtCoordinate(courtY) ? courtY : 0.5
        do {
            _ = try dataService.addShot(to: session,
                                        result: result,
                                        zone: zone,
                                        shotType: shotType,
                                        courtX: safeX,
                                        courtY: safeY)
            recentShots = Array(session.shots.suffix(5))
            lastShotResult = result
            triggerHaptic(for: result)
            let message: String
            switch result {
            case .make:
                message = "Make. \(shotsMade) for \(shotsAttempted). \(fgPercentString)."
            case .miss:
                message = "Miss. \(shotsMade) for \(shotsAttempted). \(fgPercentString)."
            default:
                return
            }
            postShotAnnouncement(message)
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
        // Phase 7 — Security: clamp coordinates to valid half-court range
        let safeX = InputValidator.isValidCourtCoordinate(courtX) ? courtX : 0.5
        let safeY = InputValidator.isValidCourtCoordinate(courtY) ? courtY : 0.5
        do {
            let shot = try dataService.addShot(to: session,
                                               result: .pending,
                                               zone: zone,
                                               shotType: .unknown,
                                               courtX: safeX,
                                               courtY: safeY,
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
        // Phase 7 — Security: clamp coordinates to valid half-court range
        let safeX = InputValidator.isValidCourtCoordinate(courtX) ? courtX : 0.5
        let safeY = InputValidator.isValidCourtCoordinate(courtY) ? courtY : 0.5
        guard let pending = pendingShotRecord else {
            logShot(result: result, zone: zone, courtX: safeX, courtY: safeY)
            return
        }
        do {
            try dataService.resolveShot(pending,
                                        result: result,
                                        zone: zone,
                                        courtX: safeX,
                                        courtY: safeY)
            pendingShotRecord = nil
            recentShots       = Array(session?.shots.suffix(5) ?? [])
            lastShotResult    = result
            triggerHaptic(for: result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Called by LiveSessionView when CourtCalibrationService changes state.
    func updateCalibrationState(isCalibrated: Bool, hoopRect: CGRect? = nil) {
        self.isCalibrated        = isCalibrated
        self.calibrationIsActive = isCalibrated
        self.detectedHoopRect    = hoopRect
    }

    /// Called per frame by CVPipeline so the debug overlay can follow the ball.
    /// Pass `nil` when no detection in the current frame.
    func updateBallDetection(box: CGRect?, confidence: Float?) {
        self.detectedBallBox        = box
        self.detectedBallConfidence = confidence
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

    // MARK: - Accessibility Announcements (private)

    private func postShotAnnouncement(_ message: String) {
        let now = Date()
        guard now.timeIntervalSince(lastAnnouncementDate) >= 2.0 else { return }
        lastAnnouncementDate = now
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
