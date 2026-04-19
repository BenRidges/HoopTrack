// GameRegistrationView.swift
// Landscape camera preview + lock progress ring + post-capture name-entry sheet.
// Wires CameraService.framePublisher → AppearanceCaptureService and forwards
// confirmed descriptors into GameRegistrationViewModel.

import SwiftUI
import Combine
import AVFoundation
import UIKit
import ImageIO

struct GameRegistrationView: View {
    @EnvironmentObject private var cameraService: CameraService
    @StateObject private var captureService = AppearanceCaptureService()
    @ObservedObject var viewModel: GameRegistrationViewModel

    let onComplete: ([GameRegistrationViewModel.PendingPlayer]) -> Void
    let onCancel: () -> Void

    @State private var pendingName: String = ""
    @State private var pendingDescriptorBlob: Data?
    @State private var showNameSheet = false
    @State private var frameSubscription: AnyCancellable?

    var body: some View {
        ZStack {
            CameraPreviewView(
                captureSession: cameraService.captureSession,
                orientation: .landscape,
                isSessionRunning: cameraService.isSessionRunning
            )
            .ignoresSafeArea()

            VStack {
                Text(viewModel.prompt)
                    .font(.headline)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 24)
                Spacer()
                HStack {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: Capsule())
                    Spacer()
                    Text(captureService.statusMessage)
                        .foregroundStyle(.white)
                        .font(.subheadline)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            Circle()
                .stroke(.white.opacity(0.4), lineWidth: 4)
                .frame(width: 120, height: 120)
                .overlay(
                    Circle()
                        .trim(from: 0, to: captureService.lockProgress)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                )
                .animation(.linear(duration: 0.1), value: captureService.lockProgress)

            #if DEBUG
            DebugKeypointOverlay(
                keypoints: captureService.debugKeypoints,
                lockProgress: captureService.lockProgress,
                threshold: HoopTrack.Game.registrationMinBodyConfidence
            )
            #endif
        }
        .task {
            if cameraService.permissionStatus == .notDetermined {
                await cameraService.requestPermission()
            }
            if cameraService.permissionStatus == .authorized {
                cameraService.configureSession(mode: .rear, orientation: .landscape)
                cameraService.startSession()
            }
            frameSubscription = cameraService.framePublisher
                .receive(on: RunLoop.main)
                .sink { buffer in
                    let orientation = visionOrientationForCurrentDevice()
                    captureService.ingest(sampleBuffer: buffer, orientation: orientation)
                }
        }
        .onDisappear {
            frameSubscription?.cancel()
            cameraService.stopSession()
        }
        .onChange(of: captureService.captured) { _, new in
            guard let descriptor = new else { return }
            do {
                pendingDescriptorBlob = try JSONEncoder().encode(descriptor)
                showNameSheet = true
            } catch {
                captureService.reset()
            }
        }
        .sheet(isPresented: $showNameSheet) {
            NavigationStack {
                Form {
                    Section("Name") {
                        TextField("Player name", text: $pendingName)
                            .textInputAutocapitalization(.words)
                    }
                }
                .navigationTitle("Confirm player")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Retake") {
                            pendingName = ""
                            pendingDescriptorBlob = nil
                            showNameSheet = false
                            captureService.reset()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Confirm") {
                            if let blob = pendingDescriptorBlob, !pendingName.isEmpty {
                                viewModel.confirmPlayer(name: pendingName, descriptor: blob)
                            }
                            pendingName = ""
                            pendingDescriptorBlob = nil
                            showNameSheet = false
                            captureService.reset()
                            if viewModel.isComplete {
                                onComplete(viewModel.pendingPlayers)
                            }
                        }
                        .disabled(pendingName.isEmpty)
                    }
                }
            }
        }
    }

    /// Map the live device orientation to a CGImagePropertyOrientation that
    /// tells Vision where "up" is in the camera buffer. The camera is
    /// configured with `videoRotationAngle = 0` (landscape), so buffers
    /// arrive in landscape-right native orientation. For other device
    /// orientations we need to tell Vision how to interpret that buffer.
    ///
    /// Rear camera only — front camera would need mirrored variants.
    private func visionOrientationForCurrentDevice() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .portrait:            return .right
        case .portraitUpsideDown:  return .left
        case .landscapeLeft:       return .down
        case .landscapeRight:      return .up
        default:                   return .right    // sensible default (portrait)
        }
    }
}

// MARK: - DEBUG overlay

#if DEBUG
private struct DebugKeypointOverlay: View {
    let keypoints: [String: Float]
    let lockProgress: Double
    let threshold: Float

    var body: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("CV debug")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    ForEach(orderedKeys, id: \.self) { key in
                        let conf = keypoints[key] ?? 0
                        HStack(spacing: 6) {
                            Text(key)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(width: 80, alignment: .leading)
                            Text(String(format: "%.2f", conf))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(conf >= threshold ? .green : .red)
                        }
                    }
                    Divider().background(.white.opacity(0.3))
                    HStack(spacing: 6) {
                        Text("progress")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 80, alignment: .leading)
                        Text(String(format: "%.0f%%", lockProgress * 100))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
                .padding(8)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .padding(.trailing, 12)
                .padding(.top, 12)
            }
            Spacer()
        }
    }

    private var orderedKeys: [String] {
        ["L-shoulder", "R-shoulder", "L-hip", "R-hip"]
    }
}
#endif
