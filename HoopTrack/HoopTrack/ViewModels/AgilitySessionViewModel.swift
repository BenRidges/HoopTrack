// AgilitySessionViewModel.swift
// Timed agility runs: ready → countdown → running → recorded → ready.
// Times come from the clock (Date), not from counting timer ticks — the old
// 0.01 s Timer drifted, and its volume-button trigger stopped responding
// once the volume hit maximum.

import Foundation
import Combine

@MainActor final class AgilitySessionViewModel: ObservableObject {

    enum Metric: String, CaseIterable, Identifiable {
        case shuttleRun = "Shuttle run"
        case laneAgility = "Lane agility"
        var id: String { rawValue }
    }

    enum RunState: Equatable {
        case ready
        case countdown(Int)
        case running(since: Date)
        case recorded(Double)
    }

    @Published var metric: Metric
    @Published private(set) var state: RunState = .ready
    @Published private(set) var shuttleAttempts: [Double] = []
    @Published private(set) var laneAttempts: [Double] = []
    @Published private(set) var isEnding = false
    @Published var errorMessage: String?

    var attempts: [Double] { metric == .shuttleRun ? shuttleAttempts : laneAttempts }
    var best: Double? { attempts.min() }

    let namedDrill: NamedDrill?
    private let dataService: DataService
    private let coordinator: SessionFinalizationCoordinator
    private let haptics: HapticService
    private var session: TrainingSession?
    private let startedAt = Date.now
    private var countdownTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?

    init(namedDrill: NamedDrill?, dataService: DataService,
         coordinator: SessionFinalizationCoordinator, haptics: HapticService) {
        self.namedDrill = namedDrill
        self.dataService = dataService
        self.coordinator = coordinator
        self.haptics = haptics
        self.metric = namedDrill == .laneAgility ? .laneAgility : .shuttleRun
    }

    func start() {
        guard session == nil else { return }
        do {
            session = try dataService.startSession(drillType: .agility, namedDrill: namedDrill)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The one big button: start the countdown, or stop the clock.
    func tap() {
        switch state {
        case .ready, .recorded:
            beginCountdown()
        case .countdown:
            countdownTask?.cancel()
            state = .ready
        case .running(let since):
            let time = Date.now.timeIntervalSince(since)
            haptics.milestone()
            if metric == .shuttleRun { shuttleAttempts.append(time) } else { laneAttempts.append(time) }
            state = .recorded(time)
            resetTask?.cancel()
            resetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled, let self, case .recorded = self.state else { return }
                self.state = .ready
            }
        }
    }

    private func beginCountdown() {
        resetTask?.cancel()
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            for n in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.state = .countdown(n)
                self.haptics.tap()
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            self.haptics.longPress()
            self.state = .running(since: .now)
        }
    }

    /// Finishes the session. Nil when an end is already under way.
    func end() async -> SessionEnd? {
        guard !isEnding else { return nil }
        isEnding = true
        countdownTask?.cancel()
        resetTask?.cancel()
        guard let session else { return .discarded }
        if shuttleAttempts.isEmpty && laneAttempts.isEmpty {
            dataService.discardSession(session)
            return .discarded
        }
        let attempts = AgilityAttempts(bestShuttleRunSeconds: shuttleAttempts.min(),
                                       bestLaneAgilitySeconds: laneAttempts.min())
        do {
            return .saved(try await coordinator.finaliseAgilitySession(
                session, attempts: attempts, activeDuration: Date.now.timeIntervalSince(startedAt)))
        } catch {
            errorMessage = error.localizedDescription
            isEnding = false
            return .failed
        }
    }

    /// Called if the view goes away without `end()`: keeps recorded runs.
    func tearDown() {
        guard !isEnding else { return }
        isEnding = true
        countdownTask?.cancel()
        resetTask?.cancel()
        guard let session else { return }
        if shuttleAttempts.isEmpty && laneAttempts.isEmpty {
            dataService.discardSession(session)
        } else {
            let attempts = AgilityAttempts(bestShuttleRunSeconds: shuttleAttempts.min(),
                                           bestLaneAgilitySeconds: laneAttempts.min())
            let active = Date.now.timeIntervalSince(startedAt)
            Task { [coordinator] in
                _ = try? await coordinator.finaliseAgilitySession(session, attempts: attempts, activeDuration: active)
            }
        }
    }
}
