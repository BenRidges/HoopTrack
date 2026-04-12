// AgilitySessionViewModel.swift
// Owns the agility drill state machine: idle → running → recorded (auto-reset after 1.5s).

import Foundation
import Combine

@MainActor final class AgilitySessionViewModel: ObservableObject {

    enum TimerState { case idle, running, recorded }
    enum AgilityMetric: String, CaseIterable { case shuttleRun = "Shuttle Run", laneAgility = "Lane Agility" }

    // MARK: - Published state

    @Published var timerState: TimerState = .idle
    @Published var selectedMetric: AgilityMetric = .shuttleRun
    @Published var elapsedSeconds: Double = 0
    @Published var shuttleAttempts: [Double] = []
    @Published var laneAttempts:    [Double] = []
    @Published var isFinished:  Bool = false
    @Published var isSaving:    Bool = false
    @Published var errorMessage: String?
    @Published var sessionResult: SessionResult?

    // MARK: - Computed

    var bestShuttleSeconds: Double? { shuttleAttempts.min() }
    var bestLaneSeconds:    Double? { laneAttempts.min() }
    var currentAttempts:    [Double] { selectedMetric == .shuttleRun ? shuttleAttempts : laneAttempts }

    // MARK: - Dependencies

    private var detectionService: AgilityDetectionServiceProtocol!
    private var coordinator:      SessionFinalizationCoordinator!
    private var dataService:      DataService!
    private var session:          TrainingSession?
    private var timerCancellable: AnyCancellable?
    private var resetTask:        Task<Void, Never>?

    // MARK: - Configuration

    func configure(dataService: DataService,
                   coordinator: SessionFinalizationCoordinator,
                   detectionService: AgilityDetectionServiceProtocol) {
        self.dataService      = dataService
        self.coordinator      = coordinator
        self.detectionService = detectionService
        self.detectionService.onTrigger = { [weak self] in self?.handleTrigger() }
    }

    // MARK: - Lifecycle

    func start(namedDrill: NamedDrill?) throws {
        session = try dataService.startSession(drillType: .agility, namedDrill: namedDrill)
        detectionService.startListening()
    }

    func endSession() async {
        detectionService.stopListening()
        guard let session else { return }
        isSaving = true
        let attempts = AgilityAttempts(
            bestShuttleRunSeconds:  bestShuttleSeconds,
            bestLaneAgilitySeconds: bestLaneSeconds
        )
        do {
            sessionResult = try await coordinator.finaliseAgilitySession(session, attempts: attempts)
            isFinished    = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: - State Machine

    private func handleTrigger() {
        switch timerState {
        case .idle:
            // Start timing
            timerState = .running
            startTimer()
        case .running:
            // Stop timing, record result
            let elapsed = elapsedSeconds
            stopTimer()
            timerState = .recorded
            if selectedMetric == .shuttleRun {
                shuttleAttempts.append(elapsed)
            } else {
                laneAttempts.append(elapsed)
            }
            elapsedSeconds = 0
            // Auto-reset to idle after 1.5s
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                timerState = .idle
            }
        case .recorded:
            break
        }
    }

    private func startTimer() {
        timerCancellable = Timer.publish(every: 0.01, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.elapsedSeconds += 0.01
            }
    }

    private func stopTimer() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }
}
