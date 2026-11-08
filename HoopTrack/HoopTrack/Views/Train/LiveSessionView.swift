// LiveSessionView.swift
// Landscape, full-bleed camera. Everything you need at a glance from 20 ft
// away: score top-left, hoop status top-centre, clock top-right. Make /
// Miss / Undo are the input when nothing is tracking. While the hoop is
// tracked they stay out of the picture until the screen is tapped, and
// right after a call the other result changes it rather than adding a shot.

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
    @AppStorage(AppPreferences.Key.showDetectionBoxes) private var showDetectionBoxes = false

    @StateObject private var holder = ViewModelHolder()

    var body: some View {
        ZStack {
            if let viewModel = holder.viewModel {
                LiveSessionContent(viewModel: viewModel,
                                   showDetectionBoxes: showDetectionBoxes,
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
                                                        haptics: hapticService)
            }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
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
    let onFinish: (SessionEnd?) -> Void

    @EnvironmentObject private var cameraService: CameraService
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var saveFailed = false
    /// Make / Miss / Undo brought up by a tap while tracking; each tap or
    /// button press keeps them up a little longer.
    @State private var controlsRevealed = false
    @State private var revealCount = 0

    var body: some View {
        ZStack {
            // A tap anywhere on the picture brings up Make / Miss / Undo.
            ZStack { camera }
                .contentShape(Rectangle())
                .onTapGesture { revealControls() }
            ShotFlashOverlay(flash: viewModel.lastShot)
            hud
            if let moment = viewModel.playoffMoment, let run = viewModel.playoff, !viewModel.isPaused {
                PlayoffMomentCard(moment: moment, run: run, comebackZone: viewModel.comebackZone,
                                  onDismiss: { viewModel.dismissPlayoffMoment() },
                                  onFinish: { finish() })
                    .id(moment.id)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if viewModel.isPaused { pausedOverlay }
            if showsHoopCoach { hoopCoach }
        }
        .animation(.snappy, value: viewModel.playoffMoment)
        .animation(.easeInOut(duration: 0.2), value: showsShotButtons)
        .task { await viewModel.start(showDetectionBoxes: showDetectionBoxes) }
        .task(id: revealCount) {
            guard revealCount > 0 else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { controlsRevealed = false }
        }
        .onChange(of: autoTracking) { _, tracking in
            // Tracking found the hoop again: let the buttons linger, then go.
            if tracking { revealControls() }
        }
        .onChange(of: viewModel.timeIsUp) { _, up in
            if up { finish() }
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
        if cameraService.permissionStatus == .authorized {
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
        }
    }

    // MARK: - HUD

    private var hud: some View {
        VStack {
            HStack(alignment: .top) {
                if let run = viewModel.playoff {
                    PlayoffScoreboard(run: run, comebackZone: viewModel.comebackZone)
                } else {
                    scoreBlock
                }
                Spacer()
                statusPill
                Spacer()
                clockBlock
            }
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    recentStrip
                    HoldToEndButton(isBusy: viewModel.phase == .ending) { finish() }
                }
                Spacer()
                shotButtons
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var scoreBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(viewModel.makes)")
                    .font(.score(56))
                Text("/\(viewModel.attempts)")
                    .font(.score(32))
                    .foregroundStyle(.white.opacity(0.6))
            }
            if let fg = viewModel.fgPercent {
                Text("\(Int(fg.rounded()))%")
                    .font(.score(28))
                    .foregroundStyle(Color.shooting(fg))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(viewModel.makes.counted("make")) from \(viewModel.attempts.counted("shot"))")
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.5), in: Capsule())
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if viewModel.shotInFlight { return "Shot in the air" }
        switch viewModel.hoopStatus {
        case .manual:    return "Manual scoring"
        case .searching: return "Finding the hoop"
        case .tracking:  return "Tracking"
        case .lost:      return "Hoop out of view"
        }
    }

    private var statusColor: Color {
        if viewModel.shotInFlight { return .leather }
        switch viewModel.hoopStatus {
        case .manual:    return .white.opacity(0.5)
        case .searching: return .leather
        case .tracking:  return .make
        case .lost:      return .miss
        }
    }

    private var clockBlock: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(clockText(at: context.date))
                    .font(.score(32))
                    .foregroundStyle(.white)
            }
            Button {
                viewModel.togglePause()
            } label: {
                Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel(viewModel.isPaused ? "Resume" : "Pause")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.5), in: Capsule())
    }

    private func clockText(at date: Date) -> String {
        let elapsed = viewModel.activeElapsed(at: date)
        if let limit = viewModel.timeLimit {
            return max(0, limit - elapsed).clockText
        }
        return elapsed.clockText
    }

    private var recentStrip: some View {
        HStack(spacing: 5) {
            ForEach(Array(viewModel.recentResults.enumerated()), id: \.offset) { _, result in
                Circle()
                    .fill(result.color)
                    .frame(width: 10, height: 10)
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    /// The tracker has the hoop, so shots are being called on their own.
    private var autoTracking: Bool {
        viewModel.hoopStatus == .tracking && !viewModel.skippedHoopSearch
    }

    private var showsShotButtons: Bool {
        !autoTracking || controlsRevealed || voiceOver
    }

    private func revealControls() {
        controlsRevealed = true
        revealCount += 1
    }

    @ViewBuilder
    private var shotButtons: some View {
        if showsShotButtons {
            shotButtonRow
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            // Where the buttons are: a tap anywhere brings them back.
            Image(systemName: "hand.tap")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.35), in: Circle())
                .onTapGesture { revealControls() }
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    private var shotButtonRow: some View {
        let manual = viewModel.hoopStatus == .manual || viewModel.skippedHoopSearch
        let size: CGFloat = manual ? 76 : 58
        return HStack(spacing: 14) {
            Button {
                viewModel.undoLast()
                revealControls()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.5), in: Circle())
            }
            .disabled(viewModel.attempts == 0)
            .opacity(viewModel.attempts == 0 ? 0.4 : 1)
            .accessibilityLabel("Undo last shot")

            let changes = viewModel.correctableShot?.result
            roundButton("Miss", systemImage: "xmark", color: .miss, size: size,
                        hint: changes == .make ? "Changes the last call to a miss" : nil) {
                viewModel.logManual(.miss)
                revealControls()
            }
            roundButton("Make", systemImage: "checkmark", color: .make, size: size,
                        hint: changes == .miss ? "Changes the last call to a make" : nil) {
                viewModel.logManual(.make)
                revealControls()
            }
        }
        .foregroundStyle(.white)
        .disabled(viewModel.phase != .live || viewModel.isPaused)
    }

    private func roundButton(_ title: String, systemImage: String, color: Color,
                             size: CGFloat, hint: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.36, weight: .heavy))
                .foregroundStyle(Color.onLeather)
                .frame(width: size, height: size)
                .background(color, in: Circle())
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
        .accessibilityInputLabels([title, title == "Make" ? "Score" : "Missed"])
    }

    // MARK: - Overlays

    private var showsHoopCoach: Bool {
        viewModel.phase == .live && viewModel.hoopStatus == .searching
            && !viewModel.skippedHoopSearch && cameraService.permissionStatus == .authorized
    }

    /// First-run guidance until the rim is found. The camera stays visible
    /// so you can aim; dismiss to score by hand.
    private var hoopCoach: some View {
        VStack(spacing: 14) {
            Image(systemName: "viewfinder")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.leather)
            Text("Point the camera at the hoop")
                .font(.title3.bold())
            Text("Phone sideways and steady, about 3 m behind where you shoot. The whole rim should be in view.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            Button("Score by hand instead") {
                viewModel.skippedHoopSearch = true
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.leather)
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 380)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .transition(.opacity)
    }

    private var pausedOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("PAUSED")
                    .font(.score(48))
                    .foregroundStyle(.white)
                Button {
                    viewModel.togglePause()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(width: 200)
                }
                .buttonStyle(.primary)
                .frame(width: 220)
            }
        }
    }
}
