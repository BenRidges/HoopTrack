// HoopTrack/ViewModels/DribbleSessionViewModel.swift
// Owns all state for a live dribble drill session.
// Mirrors LiveSessionViewModel's lifecycle (start/pause/resume/end).

import Foundation
import Combine

@MainActor
final class DribbleSessionViewModel: ObservableObject, DribblePipelineDelegate {

    // MARK: - Published
    @Published var session: TrainingSession?
    @Published var elapsedSeconds: Double = 0
    @Published var isPaused: Bool = false
    @Published var isFinished: Bool = false
    @Published var isSaving: Bool = false
    @Published var errorMessage: String?
    @Published var liveMetrics = DribbleLiveMetrics()

    // MARK: - Computed HUD values
    var totalDribbles: Int    { liveMetrics.totalDribbles }
    var currentBPS: Double    { liveMetrics.currentBPS }
    var combosDetected: Int   { liveMetrics.combosDetected }

    var elapsedFormatted: String {
        let mins = Int(elapsedSeconds) / 60
        let secs = Int(elapsedSeconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Dependencies
    private var dataService: DataService!
    private var timerCancellable: AnyCancellable?

    init() {}

    init(dataService: DataService) {
        self.dataService = dataService
    }

    func configure(dataService: DataService) {
        self.dataService = dataService
    }

    // MARK: - Lifecycle

    func start(namedDrill: NamedDrill?) {
        do {
            session = try dataService.startSession(drillType: .dribble,
                                                   namedDrill: namedDrill)
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
            try dataService.finaliseDribbleSession(session, metrics: liveMetrics)
            isFinished = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: - DribblePipelineDelegate
    // DribblePipelineDelegate is @MainActor and DribblePipeline dispatches to main
    // before invoking this method, so no nonisolated qualifier is needed.

    func pipeline(_ pipeline: DribblePipeline,
                  didUpdate metrics: DribbleLiveMetrics) {
        liveMetrics = metrics
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
}
