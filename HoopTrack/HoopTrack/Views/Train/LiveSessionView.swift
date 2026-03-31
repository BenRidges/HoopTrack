// LiveSessionView.swift
// Full-screen camera view shown during an active training session.
//
// Phase 1: Camera preview + manual shot logging buttons + HUD.
// Phase 2: CV pipeline makes/misses auto-populate via LiveSessionViewModel.logShot().
// Phase 3: Shot Science overlay during replay.

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

    @StateObject private var viewModel = LiveSessionViewModel()

    @State private var showMidSessionBreakdown = false
    @State private var isLongPressingEnd = false
    @State private var endLongPressProgress: Double = 0
    @State private var endSessionTask: Task<Void, Never>?
    @State private var showMakeAnimation = false
    @State private var showMissAnimation = false

    var body: some View {
        ZStack {
            // MARK: Camera Preview
            CameraPreviewView(captureSession: cameraService.captureSession)
                .ignoresSafeArea()

            // Camera permission overlay
            if cameraService.permissionStatus != .authorized {
                Color.black.ignoresSafeArea()
                CameraPermissionView()
            }

            // MARK: HUD Overlay
            VStack {
                topHUD
                Spacer()
                if showMakeAnimation { makeAnimation }
                if showMissAnimation { missAnimation }
                Spacer()
                recentShotsStrip
                bottomControls
            }
            .ignoresSafeArea(edges: .bottom)

            // MARK: Mid-session breakdown sheet
        }
        .task {
            // Inject real dependencies before starting the session
            viewModel.configure(
                dataService: DataService(modelContext: modelContext),
                hapticService: hapticService
            )

            // Start camera + session
            if cameraService.permissionStatus == .notDetermined {
                await cameraService.requestPermission()
            }
            if cameraService.permissionStatus == .authorized {
                cameraService.configureSession(mode: .rear)
                cameraService.startSession()
            }
            viewModel.start(drillType: drillType,
                            namedDrill: namedDrill,
                            courtType: .nba)
        }
        .onDisappear {
            cameraService.stopSession()
        }
        .onChange(of: viewModel.lastShotResult) { _, result in
            guard let result else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                showMakeAnimation = result == .make
                showMissAnimation = result == .miss
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                showMakeAnimation = false
                showMissAnimation = false
            }
        }
        .sheet(isPresented: $showMidSessionBreakdown) {
            MidSessionBreakdownView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $viewModel.isFinished) {
            if let session = viewModel.session {
                SessionSummaryView(session: session) {
                    viewModel.isFinished = false
                    onFinish()
                }
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Top HUD

    private var topHUD: some View {
        HStack(alignment: .top) {
            // FG% counter
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.fgPercentString)
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                Text("\(viewModel.shotsMade) / \(viewModel.shotsAttempted)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(16)
            .background(.ultraThinMaterial.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer()

            // Session timer
            VStack(alignment: .trailing, spacing: 2) {
                Text(viewModel.elapsedFormatted)
                    .font(.system(size: 36, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                if viewModel.isPaused {
                    Text("PAUSED")
                        .font(.caption.bold())
                        .foregroundStyle(.yellow)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    // MARK: - Make / Miss Animations

    private var makeAnimation: some View {
        VStack {
            Text("MAKE")
                .font(.system(size: 48, weight: .black, design: .rounded))
                .foregroundStyle(.green)
                .shadow(color: .green.opacity(0.6), radius: 16)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var missAnimation: some View {
        VStack {
            Text("MISS")
                .font(.system(size: 48, weight: .black, design: .rounded))
                .foregroundStyle(.red)
                .shadow(color: .red.opacity(0.6), radius: 16)
                .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Recent Shots Strip (last 5)

    private var recentShotsStrip: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.recentShots) { shot in
                Circle()
                    .fill(shot.isMake ? Color.green : Color.red)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle().stroke(.white.opacity(0.4), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.7),
                    in: Capsule())
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 12) {
            // Phase 1: Manual make/miss buttons (replaced by CV in Phase 2)
            HStack(spacing: 20) {
                // Miss button
                Button {
                    viewModel.logShot(result: .miss)
                } label: {
                    Label("Miss", systemImage: "xmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }

                // Make button
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

            HStack(spacing: 16) {
                // Pause / Resume
                Button {
                    viewModel.isPaused ? viewModel.resume() : viewModel.pause()
                    hapticService.tap()
                } label: {
                    Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }

                // Mid-session breakdown
                Button {
                    hapticService.tap()
                    showMidSessionBreakdown = true
                } label: {
                    Image(systemName: "chart.bar.fill")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Spacer()

                // End Session (long press – hold to confirm)
                Text(isLongPressingEnd ? "Hold…" : "End Session")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 20)
                    .frame(height: 52)
                    .background(
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 26).fill(Color.red)
                            RoundedRectangle(cornerRadius: 26)
                                .fill(Color.white.opacity(0.25))
                                .frame(width: max(0, endLongPressProgress) * 160)
                                .animation(.linear(duration: 0.05), value: endLongPressProgress)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 26))
                    )
                    .foregroundStyle(.white)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !isLongPressingEnd else { return }
                                isLongPressingEnd = true
                                endLongPressProgress = 0
                                withAnimation(.linear(duration: 1.5)) {
                                    endLongPressProgress = 1
                                }
                                endSessionTask = Task {
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    guard !Task.isCancelled else { return }
                                    hapticService.longPress()
                                    viewModel.endSession()
                                }
                            }
                            .onEnded { _ in
                                endSessionTask?.cancel()
                                endSessionTask = nil
                                isLongPressingEnd = false
                                withAnimation(.easeOut(duration: 0.2)) {
                                    endLongPressProgress = 0
                                }
                            }
                    )
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.black.opacity(0.4))
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
