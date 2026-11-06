// DribbleDrillView.swift
// Portrait, front camera. Prop the phone up facing you, step back until
// your whole body is in view, and dribble. One big number: the count.

import SwiftUI
import UIKit
import Combine
import AVFoundation

struct DribbleDrillView: View {

    let namedDrill: NamedDrill?
    let onFinish: (SessionResult?) -> Void

    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject private var coordinator: SessionFinalizationCoordinator
    @EnvironmentObject private var cameraService: CameraService
    @EnvironmentObject private var hapticService: HapticService
    @StateObject private var holder = Holder()

    final class Holder: ObservableObject {
        @Published var viewModel: DribbleSessionViewModel?
    }

    var body: some View {
        ZStack {
            if let viewModel = holder.viewModel {
                DribbleContent(viewModel: viewModel, onFinish: onFinish)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .statusBarHidden(true)
        .onAppear {
            if holder.viewModel == nil {
                holder.viewModel = DribbleSessionViewModel(namedDrill: namedDrill, dataService: dataService,
                                                           coordinator: coordinator, camera: cameraService,
                                                           haptics: hapticService)
            }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            holder.viewModel?.tearDown()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

private struct DribbleContent: View {
    @ObservedObject var viewModel: DribbleSessionViewModel
    let onFinish: (SessionResult?) -> Void
    @EnvironmentObject private var cameraService: CameraService

    var body: some View {
        ZStack {
            if cameraService.permissionStatus == .authorized {
                CameraPreviewView(captureSession: cameraService.captureSession,
                                  orientation: .portrait,
                                  isSessionRunning: cameraService.isSessionRunning)
                    .ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.75)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            } else {
                Color.court.ignoresSafeArea()
                CameraPermissionView()
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if !viewModel.metrics.isPlayerVisible && cameraService.isSessionRunning && !viewModel.isPaused {
                    Text("Step back so your whole body is in view")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 20)
                }
                counter
                HoldToEndButton(isBusy: viewModel.isEnding) {
                    Task { onFinish(await viewModel.end()) }
                }
                .padding(.top, 28)
            }
            .padding(Metrics.screenPadding)

            if viewModel.isPaused {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("PAUSED").font(.score(48)).foregroundStyle(.white)
                    Button { viewModel.togglePause() } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(.primary)
                        .frame(width: 220)
                }
            }
        }
        .task { await viewModel.start() }
        .onChange(of: cameraService.permissionStatus) { _, _ in
            viewModel.cameraPermissionChanged()
        }
    }

    private var topBar: some View {
        HStack {
            Text(viewModel.namedDrill?.displayName ?? "Ball handling")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(viewModel.activeElapsed(at: context.date).clockText)
                    .font(.score(28))
                    .foregroundStyle(.white)
            }
            Button { viewModel.togglePause() } label: {
                Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel(viewModel.isPaused ? "Resume" : "Pause")
        }
    }

    private var counter: some View {
        VStack(spacing: 10) {
            Text("\(viewModel.metrics.totalDribbles)")
                .font(.score(120))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: viewModel.metrics.totalDribbles)
            HStack(spacing: 24) {
                VStack(spacing: 0) {
                    Text(String(format: "%.1f", viewModel.metrics.currentBPS))
                        .font(.score(30))
                        .foregroundStyle(bpsColor)
                    Text("per second").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                VStack(spacing: 0) {
                    Text("\(viewModel.metrics.leftHandDribbles) · \(viewModel.metrics.rightHandDribbles)")
                        .font(.score(30))
                        .foregroundStyle(.white)
                    Text("left · right").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(viewModel.metrics.totalDribbles) dribbles")
    }

    private var bpsColor: Color {
        let bps = viewModel.metrics.currentBPS
        if bps >= HoopTrack.Dribble.optimalBPSMin { return .make }
        return bps > 0 ? .leather : .white
    }
}
