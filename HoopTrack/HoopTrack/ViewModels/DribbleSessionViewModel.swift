// HoopTrack/ViewModels/DribbleSessionViewModel.swift
// One live dribble session: front camera, pipeline, active-time clock.

import Foundation
import Combine

@MainActor
final class DribbleSessionViewModel: ObservableObject, DribblePipelineDelegate {

    @Published private(set) var metrics = DribbleLiveMetrics()
    @Published private(set) var isPaused = false
    @Published private(set) var isEnding = false
    @Published var errorMessage: String?

    let namedDrill: NamedDrill?
    private let dataService: DataService
    private let coordinator: SessionFinalizationCoordinator
    private let camera: CameraService
    private let haptics: HapticService
    private let pipeline = DribblePipeline()
    private var session: TrainingSession?
    private var runningSince: Date?
    private var accumulated: TimeInterval = 0
    private var isCounting = false

    init(namedDrill: NamedDrill?, dataService: DataService, coordinator: SessionFinalizationCoordinator,
         camera: CameraService, haptics: HapticService) {
        self.namedDrill = namedDrill
        self.dataService = dataService
        self.coordinator = coordinator
        self.camera = camera
        self.haptics = haptics
    }

    func start() async {
        guard session == nil else { return }
        if camera.permissionStatus == .notDetermined { await camera.requestPermission() }
        do {
            session = try dataService.startSession(drillType: .dribble, namedDrill: namedDrill)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        runningSince = .now
        startCounting()
    }

    /// Starts counting if camera access arrives mid-session (from Settings).
    func cameraPermissionChanged() {
        guard session != nil, !isEnding else { return }
        startCounting()
    }

    private func startCounting() {
        guard !isCounting, camera.permissionStatus == .authorized else { return }
        isCounting = true
        camera.configureSession(mode: .front, orientation: .portrait)
        camera.startSession()
        pipeline.isPaused = isPaused
        pipeline.start(framePublisher: camera.framePublisher, delegate: self)
    }

    func activeElapsed(at date: Date = .now) -> TimeInterval {
        accumulated + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    func togglePause() {
        isPaused.toggle()
        pipeline.isPaused = isPaused
        if isPaused {
            if let since = runningSince { accumulated += Date.now.timeIntervalSince(since) }
            runningSince = nil
        } else {
            runningSince = .now
        }
        haptics.tap()
    }

    func end() async -> SessionResult? {
        guard !isEnding, let session else { return nil }
        isEnding = true
        let active = activeElapsed()
        pipeline.stop()
        camera.stopSession()
        if metrics.totalDribbles == 0 && active < 20 {
            dataService.discardSession(session)
            return nil
        }
        do {
            return try await coordinator.finaliseDribbleSession(session, metrics: metrics, activeDuration: active)
        } catch {
            errorMessage = error.localizedDescription
            isEnding = false
            return nil
        }
    }

    /// Called if the view goes away without `end()`. Keeps a session with
    /// dribbles in it (the old version left it unfinished and invisible).
    func tearDown() {
        guard !isEnding else { return }
        isEnding = true
        let active = activeElapsed()
        pipeline.stop()
        camera.stopSession()
        guard let session else { return }
        if metrics.totalDribbles == 0 {
            dataService.discardSession(session)
        } else {
            let metrics = self.metrics
            Task { [coordinator] in
                _ = try? await coordinator.finaliseDribbleSession(session, metrics: metrics, activeDuration: active)
            }
        }
    }

    // MARK: DribblePipelineDelegate

    func pipeline(didUpdate metrics: DribbleLiveMetrics) {
        if metrics.totalDribbles > self.metrics.totalDribbles,
           metrics.totalDribbles.isMultiple(of: 50) {
            haptics.milestone()
        }
        self.metrics = metrics
    }
}
