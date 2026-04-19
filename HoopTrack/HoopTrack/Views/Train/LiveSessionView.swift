// LiveSessionView.swift
// Full-screen landscape camera view shown during an active training session.
//
// Phase 1: Camera preview + manual shot logging buttons + HUD.
// Phase 2: CV pipeline makes/misses auto-populate via LiveSessionViewModel.logShot().
// Phase 3: Shot Science overlay during replay.
// Landscape: Always-landscape with right sidebar layout and border glow animations.

import SwiftUI
import AVFoundation
import SwiftData

struct LiveSessionView: View {

    let drillType: DrillType
    let namedDrill: NamedDrill?
    let onFinish: () -> Void

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var cameraService: CameraService
    @EnvironmentObject private var hapticService: HapticService
    @EnvironmentObject private var notificationService: NotificationService
    @EnvironmentObject private var coordinator: SessionFinalizationCoordinator
    @EnvironmentObject private var dataService: DataService

    @StateObject private var viewModel = LiveSessionViewModel()

    @State private var showMidSessionBreakdown = false
    @State private var isStatsExpanded = false
    private let sidebarWidth: CGFloat = 140

    // Phase 2: CV pipeline
    @State private var cvPipeline:  CVPipeline?
    @State private var calibration: CourtCalibrationService?

    // Phase 3: video recording for Shot Science replay
    @State private var videoRecorder: VideoRecordingService?

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // MARK: Camera Area (~80%)
                ZStack {
                    CameraPreviewView(captureSession: cameraService.captureSession,
                                      orientation: .landscape,
                                      isSessionRunning: cameraService.isSessionRunning)
                        .ignoresSafeArea()

                    // Detection debug overlay — rim (green) and ball (orange)
                    DetectionOverlay(hoopRect: viewModel.detectedHoopRect,
                                     ballBox:  viewModel.detectedBallBox,
                                     ballConfidence: viewModel.detectedBallConfidence)

                    // Camera permission overlay
                    if cameraService.permissionStatus != .authorized {
                        Color.black.ignoresSafeArea()
                        CameraPermissionView()
                    }

                    // Manual make/miss fallback — shown only when CV pipeline is not active
                    if cvPipeline == nil {
                        VStack {
                            Spacer()
                            manualShotButtons
                                .padding(.bottom, 20)
                                .padding(.horizontal, 20)
                        }
                    }

                    // Phase 2: calibration prompt — shown until hoop is locked
                    if !viewModel.isCalibrated {
                        calibrationOverlay
                    }
                }

                // MARK: Right Sidebar (~20%)
                sidebar
            }

            // MARK: Shot glow overlay
            ShotGlowOverlay(shotResult: viewModel.lastShotResult,
                             sidebarWidth: sidebarWidth)
                .accessibilityHidden(true)
        }
        .task {
            viewModel.configure(
                dataService:  dataService,
                hapticService: hapticService,
                coordinator:  coordinator
            )

            if cameraService.permissionStatus == .notDetermined {
                await cameraService.requestPermission()
            }
            if cameraService.permissionStatus == .authorized {
                cameraService.configureSession(mode: .rear, orientation: .landscape)
                cameraService.startSession()
            }

            viewModel.start(drillType: drillType, namedDrill: namedDrill, courtType: .nba)

            // Phase 2: start CV pipeline (or fall back to manual-only if no model available)
            if let detector = BallDetectorFactory.make(BallDetectorFactory.active) {
                let cal = CourtCalibrationService()
                cal.onStateChange = { @Sendable [weak viewModel] state in
                    let tracking = state.isTracking
                    let hoopRect = state.hoopRect
                    Task { @MainActor [weak viewModel] in
                        viewModel?.updateCalibrationState(isCalibrated: tracking, hoopRect: hoopRect)
                    }
                }
                // Calibration is now per-frame via CVPipeline → updateBasket —
                // no explicit start step. The service is live as soon as it's
                // constructed and the pipeline starts feeding it frames.

                let poseService = PoseEstimationService()
                let pipeline = CVPipeline(detector: detector,
                                          calibration: cal,
                                          poseService: poseService)
                pipeline.start(framePublisher: cameraService.framePublisher, viewModel: viewModel)

                calibration = cal
                cvPipeline  = pipeline
            } else {
                viewModel.updateCalibrationState(isCalibrated: true)
            }

            // Phase 3: record session video for replay
            let recorder = VideoRecordingService()
            recorder.configure(captureSession: cameraService.captureSession,
                               orientation: .landscape)
            if let sessionID = viewModel.session?.id {
                recorder.startRecording(sessionID: sessionID)
                recorder.onRecordingFinished = { result in
                    if case .success(let url) = result {
                        viewModel.session?.videoFileName = url.lastPathComponent
                    }
                }
            }
            videoRecorder = recorder
        }
        .onDisappear {
            cvPipeline?.stop()
            calibration?.reset()
            videoRecorder?.stopRecording()
            cameraService.stopSession()
        }
        .sheet(isPresented: $showMidSessionBreakdown) {
            MidSessionBreakdownView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $viewModel.isFinished) {
            if let session = viewModel.session {
                SessionSummaryView(
                    session:      session,
                    badgeChanges: viewModel.sessionResult?.badgeChanges ?? [],
                    badgeSkipReason: viewModel.sessionResult?.badgeSkipReason
                ) {
                    viewModel.isFinished = false
                    onFinish()
                }
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Right Sidebar (Sport Broadcast Style)

    /// Reusable card background for sidebar sections.
    private func sidebarCard(orangeBorder: Bool = false) -> some ShapeStyle {
        LinearGradient(colors: [Color(red: 0.10, green: 0.10, blue: 0.18),
                                Color(red: 0.07, green: 0.07, blue: 0.12)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var sidebar: some View {
        VStack(spacing: 6) {

            // MARK: FG% Card (tappable, expandable)
            VStack(spacing: 4) {
                // Header row with expand chevron
                HStack {
                    Text("FIELD GOAL")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.orange.opacity(0.6))
                        .tracking(1.5)
                    Spacer()
                    Image(systemName: isStatsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.25))
                }

                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(String(format: "%.0f", viewModel.fgPercent))
                        .font(.system(.largeTitle, design: .rounded).weight(.black))
                        .foregroundStyle(fgTintColor)
                    Text("%")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(fgTintColor)
                        .baselineOffset(10)
                }
                .monospacedDigit()

                // Made / Miss split row
                HStack(spacing: 0) {
                    VStack(spacing: 1) {
                        Text("\(viewModel.shotsMade)")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.green)
                        Text("MADE")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.3))
                            .tracking(0.5)
                    }
                    .frame(maxWidth: .infinity)

                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(width: 1, height: 24)

                    VStack(spacing: 1) {
                        Text("\(viewModel.shotsAttempted - viewModel.shotsMade)")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.red)
                        Text("MISS")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.3))
                            .tracking(0.5)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(0.04))
                )
                .padding(.top, 2)

                // Expanded zone breakdown
                if isStatsExpanded {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(.white.opacity(0.06))
                            .frame(height: 1)
                            .padding(.vertical, 6)

                        if let session = viewModel.session {
                            ForEach(zoneBreakdown(for: session), id: \.zone) { row in
                                HStack(spacing: 0) {
                                    Text(row.label)
                                        .font(.system(size: 7, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.5))
                                        .tracking(0.5)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(row.fraction)
                                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .frame(width: 28, alignment: .trailing)

                                    Text(row.pct)
                                        .font(.system(size: 9, weight: .black, design: .monospaced))
                                        .foregroundStyle(row.pctColor)
                                        .frame(width: 32, alignment: .trailing)
                                }
                                .padding(.vertical, 3)
                            }

                            // Streak
                            if session.longestMakeStreak > 0 {
                                Rectangle()
                                    .fill(.white.opacity(0.06))
                                    .frame(height: 1)
                                    .padding(.vertical, 4)

                                HStack {
                                    Text("BEST RUN")
                                        .font(.system(size: 7, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .tracking(0.5)
                                    Spacer()
                                    Text("\(session.longestMakeStreak)")
                                        .font(.system(size: 11, weight: .black, design: .monospaced))
                                        .foregroundStyle(.orange)
                                    + Text(" IN A ROW")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(.orange.opacity(0.6))
                                }
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(sidebarCard())
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.orange.opacity(isStatsExpanded ? 0.25 : 0.15), lineWidth: 1)
                    )
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Field goal percentage \(viewModel.fgPercentString), \(viewModel.shotsMade) makes out of \(viewModel.shotsAttempted) attempts")
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isStatsExpanded.toggle()
                }
            }

            // MARK: Timer Card
            VStack(spacing: 2) {
                Text("TIME")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
                    .tracking(1.5)

                Text(viewModel.elapsedFormatted)
                    .font(.system(.title2, design: .monospaced).weight(.heavy))
                    .foregroundStyle(.white)
                    .tracking(1)

                if viewModel.isPaused {
                    Text("PAUSED")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(sidebarCard())
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.06), lineWidth: 1)
                    )
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(viewModel.isPaused ? "Session timer \(viewModel.elapsedFormatted), paused" : "Session timer \(viewModel.elapsedFormatted)")

            Spacer(minLength: 8)

            // MARK: Recent Shots Card
            VStack(spacing: 6) {
                Text("RECENT")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.25))
                    .tracking(1.5)

                HStack(spacing: 3) {
                    ForEach(Array(viewModel.recentShots.enumerated()), id: \.element.id) { index, shot in
                        let isLatest = index == viewModel.recentShots.count - 1
                        RoundedRectangle(cornerRadius: 3)
                            .fill(dotColor(for: shot.result))
                            .frame(width: 16, height: 5)
                            .shadow(color: isLatest ? dotColor(for: shot.result).opacity(0.5) : .clear,
                                    radius: isLatest ? 4 : 0)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(sidebarCard())
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.06), lineWidth: 1)
                    )
            )

            Spacer(minLength: 8)

            // MARK: Controls
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    // Pause / Resume
                    Button {
                        viewModel.isPaused ? viewModel.resume() : viewModel.pause()
                        hapticService.tap()
                    } label: {
                        Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 14))
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.white.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(.white.opacity(0.1), lineWidth: 1)
                                    )
                            )
                    }

                    // Mid-session breakdown
                    Button {
                        hapticService.tap()
                        showMidSessionBreakdown = true
                    } label: {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 14))
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.white.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(.white.opacity(0.1), lineWidth: 1)
                                    )
                            )
                    }
                }
                .foregroundStyle(.white.opacity(0.5))

                // End Session
                HoldToEndButton {
                    await viewModel.endSession()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: sidebarWidth)
        .background(
            LinearGradient(colors: [Color(red: 0.067, green: 0.067, blue: 0.094),
                                    Color(red: 0.031, green: 0.031, blue: 0.051)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Calibration Overlay

    private var calibrationOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.white)
            Text("Looking for hoop…")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Point the camera at the rim. Tracking stays locked even if the view shifts.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.55))
    }

    // MARK: - FG% Tint Colour

    /// Briefly tints the FG% text green or red to match the last shot result.
    private var fgTintColor: Color {
        switch viewModel.lastShotResult {
        case .make:    return .green
        case .miss:    return .red
        case .pending, .none: return .orange
        }
    }

    // MARK: - Manual Shot Buttons

    private var manualShotButtons: some View {
        HStack(spacing: 20) {
            Button {
                viewModel.logShot(result: .miss)
            } label: {
                Label("Miss", systemImage: "xmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Miss")
            .accessibilityHint("Log a missed shot")
            .accessibilityInputLabels(["Miss", "Missed", "No good"])

            Button {
                viewModel.logShot(result: .make)
            } label: {
                Label("Make", systemImage: "checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Make")
            .accessibilityHint("Log a made shot")
            .accessibilityInputLabels(["Make", "Score", "Good shot"])
        }
    }

    private func dotColor(for result: ShotResult) -> Color {
        switch result {
        case .make:    return .green
        case .miss:    return .red
        case .pending: return Color(.systemGray)
        }
    }

    // MARK: - Zone Breakdown Rows

    private struct ZoneBreakdownRow {
        let zone: CourtZone
        let label: String
        let fraction: String
        let pct: String
        let pctColor: Color
    }

    private func zoneBreakdown(for session: TrainingSession) -> [ZoneBreakdownRow] {
        session.zoneStats.map { stat in
            let pctValue = stat.fgPercent
            let color: Color
            switch pctValue {
            case 60...:  color = .green
            case 40..<60: color = .orange
            default:      color = .red
            }
            return ZoneBreakdownRow(
                zone: stat.zone,
                label: stat.zone.rawValue.uppercased(),
                fraction: "\(stat.made)/\(stat.attempted)",
                pct: String(format: "%.0f%%", pctValue),
                pctColor: color
            )
        }
    }
}

// MARK: - Mid-Session Breakdown Sheet
private struct MidSessionBreakdownView: View {
    @ObservedObject var viewModel: LiveSessionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    StatCardGrid {
                        StatCard(title: "FG%",   value: viewModel.fgPercentString)
                        StatCard(title: "Makes",  value: "\(viewModel.shotsMade)", accent: .green)
                        StatCard(title: "Misses",
                                 value: "\(viewModel.shotsAttempted - viewModel.shotsMade)",
                                 accent: .red)
                        StatCard(title: "Elapsed", value: viewModel.elapsedFormatted, accent: .blue)
                    }

                    if let session = viewModel.session, !session.shots.isEmpty {
                        CourtMapView(shots: session.shots)
                            .padding(.horizontal)
                    }
                }
                .padding()
            }
            .navigationTitle("Session so far")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - UIViewRepresentable Camera Preview
struct CameraPreviewView: UIViewRepresentable {

    let captureSession: AVCaptureSession
    var orientation: CameraOrientation = .landscape
    /// Observed so updateUIView re-fires when the session actually starts
    /// running. The preview layer's connection is nil until then, so rotation
    /// applied in makeUIView is a no-op.
    var isSessionRunning: Bool = false

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session      = captureSession
        view.previewLayer.videoGravity  = .resizeAspectFill
        applyRotation(to: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        applyRotation(to: uiView.previewLayer)
    }

    private func applyRotation(to layer: AVCaptureVideoPreviewLayer) {
        if let connection = layer.connection {
            let angle = orientation.videoRotationAngle
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
