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
                    CameraPreviewView(captureSession: cameraService.captureSession)
                        .ignoresSafeArea()

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
                }

                // MARK: Right Sidebar (~20%)
                sidebar
            }

            // Phase 2: calibration prompt — shown until hoop is locked
            if !viewModel.isCalibrated {
                calibrationOverlay
            }

            // MARK: Shot glow overlay
            ShotGlowOverlay(shotResult: viewModel.lastShotResult,
                             sidebarWidth: sidebarWidth)
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
                cal.onStateChange = { [weak viewModel] state in
                    viewModel?.updateCalibrationState(isCalibrated: state.isCalibrated)
                }
                cal.startCalibration()

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
                    badgeChanges: viewModel.sessionResult?.badgeChanges ?? []
                ) {
                    viewModel.isFinished = false
                    onFinish()
                }
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Right Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Stats — top
            VStack(spacing: 2) {
                Text(viewModel.fgPercentString)
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(fgTintColor)
                    .shadow(radius: 4)
                Text("\(viewModel.shotsMade) / \(viewModel.shotsAttempted)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))

                Divider()
                    .background(.white.opacity(0.2))
                    .padding(.vertical, 8)

                Text(viewModel.elapsedFormatted)
                    .font(.system(size: 26, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)

                if viewModel.isPaused {
                    Text("PAUSED")
                        .font(.caption.bold())
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.top, 16)

            Spacer()

            // Recent shots — middle
            VStack(spacing: 6) {
                Text("RECENT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(1)
                HStack(spacing: 5) {
                    ForEach(Array(viewModel.recentShots.enumerated()), id: \.element.id) { index, shot in
                        Circle()
                            .fill(dotColor(for: shot.result))
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .stroke(.white, lineWidth: index == viewModel.recentShots.count - 1 ? 2 : 0)
                            )
                    }
                }
            }

            Spacer()

            // Controls — bottom
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    // Pause / Resume
                    Button {
                        viewModel.isPaused ? viewModel.resume() : viewModel.pause()
                        hapticService.tap()
                    } label: {
                        Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    // Mid-session breakdown
                    Button {
                        hapticService.tap()
                        showMidSessionBreakdown = true
                    } label: {
                        Image(systemName: "chart.bar.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .foregroundStyle(.white)

                // End Session
                HoldToEndButton {
                    await viewModel.endSession()
                }
            }
            .padding(.bottom, 16)
        }
        .frame(width: sidebarWidth)
        .background(Color.black.opacity(0.85))
    }

    // MARK: - Calibration Overlay

    private var calibrationOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.white)
            Text("Aim at the hoop")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Keep the backboard in frame until the indicator turns green.")
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
        case .pending, .none: return .white
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

            Button {
                viewModel.logShot(result: .make)
            } label: {
                Label("Make", systemImage: "checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
        }
    }

    private func dotColor(for result: ShotResult) -> Color {
        switch result {
        case .make:    return .green
        case .miss:    return .red
        case .pending: return Color(.systemGray)
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

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session     = captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
