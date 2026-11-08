// LiveSessionView.swift
// Landscape, full-bleed camera, with LiveHUD drawn over it: the score and
// the clock straight on the picture, the screen's edge lit by each call,
// and every button behind a tap (always up when scoring by hand). Right
// after a call, the other result changes it rather than adding a shot.
// This file turns the session into what the HUD shows; LiveHUD draws it.
//
// Session options add setup guidance until the first shot, a named drill's
// step under the score, your best, a quiet "Paused" when nobody's shooting,
// and a screen that dims until it's touched.

import SwiftUI
import UIKit
import AVFoundation
import Combine

struct LiveSessionView: View {

    let namedDrill: NamedDrill?
    var playoffSeriesID: UUID? = nil
    let onFinish: (SessionEnd?) -> Void

    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject private var coordinator: SessionFinalizationCoordinator
    @EnvironmentObject private var cameraService: CameraService
    @EnvironmentObject private var hapticService: HapticService
    @EnvironmentObject private var announcer: SessionAnnouncer
    @AppStorage(AppPreferences.Key.showDetectionBoxes) private var showDetectionBoxes = false

    @StateObject private var holder = ViewModelHolder()
    @State private var dimmer = ScreenDimmer()

    var body: some View {
        ZStack {
            if let viewModel = holder.viewModel {
                LiveSessionContent(viewModel: viewModel,
                                   showDetectionBoxes: showDetectionBoxes,
                                   dimmer: dimmer,
                                   onFinish: onFinish)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if holder.viewModel == nil {
                holder.viewModel = LiveSessionViewModel(namedDrill: namedDrill,
                                                        playoffSeriesID: playoffSeriesID,
                                                        dataService: dataService,
                                                        coordinator: coordinator,
                                                        camera: cameraService,
                                                        haptics: hapticService,
                                                        options: AppPreferences.sessionOptions,
                                                        announcer: announcer)
            }
            UIApplication.shared.isIdleTimerDisabled = true
            if holder.viewModel?.options.dimScreen == true {
                dimmer.delay = .seconds(HoopTrack.Session.dimAfterSec)
                dimmer.start()
            }
        }
        .onDisappear {
            dimmer.stop()
            holder.viewModel?.tearDown()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Lets the view model be built from environment objects on first appear.
    final class ViewModelHolder: ObservableObject {
        deinit {} // Keep: see "Explicit deinit" in CLAUDE.md

        @Published var viewModel: LiveSessionViewModel?
    }
}

private struct LiveSessionContent: View {

    @ObservedObject var viewModel: LiveSessionViewModel
    let showDetectionBoxes: Bool
    let dimmer: ScreenDimmer
    let onFinish: (SessionEnd?) -> Void

    @EnvironmentObject private var cameraService: CameraService
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var saveFailed = false
    /// The buttons, brought up by a tap on the picture; each tap or button
    /// press keeps them up a little longer.
    @State private var controlsRevealed = false
    @State private var revealCount = 0
    /// The call on show: its word above the score and the lit edge.
    @State private var call: ShotFlash?
    /// "Move to the left corner", for a few seconds after a drill step.
    @State private var cue: DrillCue?
    /// The hoop's taken a while to find: the coach says what to check.
    @State private var longSearch = false
    /// "Good spot" shows for a moment, then gets out of the way.
    @State private var goodSpotShown = false
    /// "Tap for controls", once, when tracking first starts.
    @State private var tapHint = false
    @State private var tapHintShown = false

    var body: some View {
        ZStack {
            // A tap anywhere on the picture brings up the buttons.
            ZStack { camera }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.noteActivity()
                    revealControls()
                }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                LiveHUD(readout: readout(at: context.date), controls: controls, actions: actions)
            }
            if let moment = viewModel.playoffMoment, let run = viewModel.playoff, !viewModel.isPaused {
                PlayoffMomentCard(moment: moment, run: run, comebackZone: viewModel.comebackZone,
                                  onDismiss: { viewModel.dismissPlayoffMoment() },
                                  onFinish: { finish() })
                    .id(moment.id)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if viewModel.isPaused {
                LivePausedOverlay(isEnding: viewModel.phase == .ending,
                                  onResume: { viewModel.togglePause() },
                                  onEnd: { finish() })
                    .transition(.opacity)
            }
            if viewModel.idlePrompt {
                StillShootingCard(onEnd: { finish() }, onKeepGoing: { viewModel.noteActivity() })
            }
        }
        .animation(.snappy, value: viewModel.playoffMoment)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isPaused)
        .animation(.snappy, value: viewModel.idlePrompt)
        .animation(.easeInOut(duration: 0.25), value: call)
        .animation(.easeInOut(duration: 0.25), value: cue)
        .animation(.easeInOut(duration: 0.3), value: tapHint)
        .task { await viewModel.start(showDetectionBoxes: showDetectionBoxes) }
        .task(id: revealCount) {
            guard revealCount > 0 else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { controlsRevealed = false }
        }
        .onChange(of: viewModel.lastShot) { _, flash in
            if let flash, flash.result != .pending { call = flash }
        }
        .task(id: call?.id) {
            guard let shown = call else { return }
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled, call == shown { call = nil }
        }
        .onChange(of: viewModel.drillCue) { _, newCue in
            guard let newCue else { return }
            cue = newCue
            if newCue.isFinished { dimmer.wake() }
        }
        .task(id: cue?.id) {
            guard let shown = cue else { return }
            try? await Task.sleep(for: .seconds(shown.isFinished ? 5 : 3.5))
            if !Task.isCancelled, cue == shown { cue = nil }
        }
        .onChange(of: autoTracking) { _, tracking in
            guard tracking, !tapHintShown else { return }
            tapHintShown = true
            tapHint = true
        }
        .task(id: tapHint) {
            guard tapHint else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { tapHint = false }
        }
        .onChange(of: viewModel.timeIsUp) { _, up in
            if up { finish() }
        }
        .onChange(of: viewModel.idleTimedOut) { _, out in
            if out { finish() }
        }
        .onChange(of: viewModel.idlePrompt) { _, asking in
            // Whoever walks up to the phone should be able to read it.
            if asking { dimmer.wake() }
        }
        .task(id: showsHoopCoach) {
            longSearch = false
            guard showsHoopCoach, viewModel.options.setupCoach else { return }
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { longSearch = true }
        }
        .task(id: viewModel.setupAdvice) {
            goodSpotShown = viewModel.setupAdvice == .good
            guard goodSpotShown else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { goodSpotShown = false }
        }
        .onChange(of: cameraService.permissionStatus) { _, _ in
            viewModel.cameraPermissionChanged()
        }
        .sessionErrorAlert($viewModel.errorMessage, saveFailed: $saveFailed,
                           retry: finish, close: { onFinish(nil) })
    }

    private func finish() {
        Task {
            guard let end = await viewModel.end() else { return }
            if case .failed = end { saveFailed = true } else { onFinish(end) }
        }
    }

    // MARK: - Camera layer

    @ViewBuilder
    private var camera: some View {
        if cameraAuthorized {
            CameraPreviewView(captureSession: cameraService.captureSession,
                              orientation: .landscape,
                              isSessionRunning: cameraService.isSessionRunning)
                .ignoresSafeArea()
            HoopBracket(rect: viewModel.hoopRect, isTracking: viewModel.hoopStatus == .tracking)
                .ignoresSafeArea()
            if showDetectionBoxes {
                BallBoxOverlay(box: viewModel.ballBox).ignoresSafeArea()
            }
        } else {
            Color.court.ignoresSafeArea()
            CameraPermissionView(compact: true)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 24)
        }
    }

    private var cameraAuthorized: Bool { cameraService.permissionStatus == .authorized }

    // MARK: - What the HUD shows

    private func readout(at date: Date) -> LiveReadout {
        var readout = LiveReadout(layout: viewModel.options.layout)
        readout.word = word
        readout.makes = viewModel.makes
        readout.attempts = viewModel.attempts
        readout.percent = viewModel.fgPercent
        readout.target = viewModel.target
        readout.drill = drillLine
        readout.clock = clockText(at: date)
        readout.clockNote = viewModel.isClockWaiting ? "Starts on your first shot" : nil
        readout.playoff = viewModel.playoff
        readout.comebackZone = viewModel.comebackZone
        readout.setup = setup
        readout.edge = edge(setup: readout.setup)
        readout.tapHint = tapHint
        return readout
    }

    /// The call just made; otherwise what the session's doing, if it's
    /// anything but shooting.
    private var word: LiveReadout.Word? {
        if let call {
            let result = call.result == .make ? "MAKE" : "MISS"
            return .init(text: call.corrected ? "CHANGED TO \(result)" : result, color: call.result.color)
        }
        if viewModel.isIdle {
            return .init(text: "PAUSED · SHOOT TO CARRY ON", color: .white.opacity(0.8), isCall: false)
        }
        if viewModel.hoopStatus == .lost, !viewModel.skippedHoopSearch, viewModel.attempts > 0 {
            return .init(text: "HOOP OUT OF VIEW", color: .leather, isCall: false)
        }
        if let run = viewModel.playoff {
            return .init(text: PlayoffScoreboard.caption(for: run), color: .white.opacity(0.8), isCall: false)
        }
        return nil
    }

    private var drillLine: LiveReadout.Drill? {
        if let cue { return cue.isFinished ? .done(cue.text) : .cue(cue.text) }
        guard let progress = viewModel.drillProgress else { return nil }
        if progress.isFinished { return .done("Drill done") }
        let name = progress.stepCount == nil ? progress.stepLabel : progress.spot
        return .step(name, toGo: progress.shotsToGo)
    }

    private func clockText(at date: Date) -> String {
        let elapsed = viewModel.activeElapsed(at: date)
        if let limit = viewModel.timeLimit {
            return max(0, limit - elapsed).clockText
        }
        return elapsed.clockText
    }

    private var showsHoopCoach: Bool {
        viewModel.phase == .live && viewModel.hoopStatus == .searching
            && !viewModel.skippedHoopSearch && cameraAuthorized
    }

    /// The setup tip to show: problems until fixed, "Good spot" briefly.
    private var shownAdvice: SetupAdvice? {
        guard let advice = viewModel.setupAdvice, !viewModel.skippedHoopSearch,
              viewModel.phase == .live, !viewModel.isPaused else { return nil }
        return advice.isGood && !goodSpotShown ? nil : advice
    }

    /// Finding the hoop, then the setup tip, in the score's place.
    private var setup: LiveReadout.Setup? {
        guard !viewModel.isPaused else { return nil }
        if showsHoopCoach {
            return longSearch
                ? .init(title: "Still looking for the rim",
                        detail: "Check the whole rim is in the picture and there's light on it. If you're far away, move closer.",
                        offersHandScoring: true)
                : .init(title: "Point the camera at the hoop",
                        detail: "Phone sideways and steady, about 3 m behind where you shoot, with the whole rim in view.",
                        offersHandScoring: true)
        }
        if let advice = shownAdvice {
            return .init(title: advice.title, detail: advice.detail, isGood: advice.isGood)
        }
        return nil
    }

    /// Green or red with a call, dim white while paused, orange while
    /// something needs fixing, and nothing while it's all working.
    private func edge(setup: LiveReadout.Setup?) -> LiveReadout.Edge? {
        if let call { return .init(color: call.result.color) }
        if viewModel.isPaused || viewModel.isIdle { return .init(color: .white.opacity(0.35)) }
        if let setup { return setup.isGood ? .init(color: .make) : .init(color: .leather, breathing: true) }
        if viewModel.hoopStatus == .lost, cameraAuthorized, !viewModel.skippedHoopSearch {
            return .init(color: .leather)
        }
        return nil
    }

    // MARK: - Buttons

    /// Shots are called on their own.
    private var autoTracking: Bool {
        viewModel.hoopStatus == .tracking && !viewModel.skippedHoopSearch
    }

    /// Nothing calls shots, so Make and Miss are the input and stay up.
    private var scoringByHand: Bool {
        viewModel.hoopStatus == .manual || viewModel.skippedHoopSearch || !cameraAuthorized
    }

    private var controls: LiveControls {
        LiveControls(shown: controlsRevealed || voiceOver || scoringByHand,
                     large: scoringByHand,
                     canUndo: viewModel.attempts > 0,
                     changes: viewModel.correctableShot?.result,
                     enabled: viewModel.phase == .live && !viewModel.isPaused,
                     isEnding: viewModel.phase == .ending)
    }

    private var actions: LiveActions {
        LiveActions(pause: { viewModel.togglePause() },
                    end: { finish() },
                    undo: {
                        viewModel.undoLast()
                        revealControls()
                    },
                    log: { result in
                        viewModel.logManual(result)
                        revealControls()
                    },
                    scoreByHand: { viewModel.skippedHoopSearch = true })
    }

    private func revealControls() {
        controlsRevealed = true
        revealCount += 1
    }
}
