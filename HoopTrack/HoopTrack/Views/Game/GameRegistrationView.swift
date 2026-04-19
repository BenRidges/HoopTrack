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
    @State private var deviceOrientation: UIDeviceOrientation = UIDevice.current.orientation

    var body: some View {
        ZStack {
            CameraPreviewView(
                captureSession: cameraService.captureSession,
                orientation: CameraOrientation.matching(deviceOrientation),
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
        }
        .task {
            // UIDevice.current.orientation is only live while notifications
            // are being generated. Without this, it can return .unknown even
            // when the phone is clearly tilted — breaking our orientation
            // mapping and confusing Vision.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()

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
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.orientationDidChangeNotification
        )) { _ in
            let current = UIDevice.current.orientation
            // Ignore face-up / face-down / unknown — keep the last real value.
            switch current {
            case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
                deviceOrientation = current
            default:
                break
            }
        }
        .onDisappear {
            frameSubscription?.cancel()
            cameraService.stopSession()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
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
            NameConfirmSheet(
                playerNumber: viewModel.currentPlayerIndex + 1,
                totalPlayers: viewModel.totalPlayers,
                name: $pendingName,
                onRetake: {
                    pendingName = ""
                    pendingDescriptorBlob = nil
                    showNameSheet = false
                    captureService.reset()
                },
                onConfirm: {
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
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Map the live device orientation to a CGImagePropertyOrientation that
    /// tells Vision where "up" is in the camera buffer. The camera is
    /// configured with `videoRotationAngle = 0` (landscape), so buffers
    /// arrive in the sensor-native orientation.
    ///
    /// Sensor-native upright for the rear iPhone camera corresponds to
    /// `UIDeviceOrientation.landscapeLeft` (device top pointing LEFT, USB-C
    /// port on the RIGHT). This matches the existing LandscapeContainer
    /// pattern used by LiveSessionView, where `LandscapeHostingController`
    /// forces `UIInterfaceOrientation.landscapeRight` (device .landscapeLeft)
    /// and `PoseEstimationService` uses Vision orientation `.up`.
    ///
    /// Rear camera only — front camera would need mirrored variants.
    private func visionOrientationForCurrentDevice() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:       return .up        // sensor-native upright
        case .landscapeRight:      return .down      // 180° from sensor-native
        case .portrait:            return .right     // 90° CW from sensor-native
        case .portraitUpsideDown:  return .left      // 90° CCW from sensor-native
        default:                   return .right     // face-up / face-down / unknown → safe portrait default
        }
    }
}

// MARK: - Name confirmation sheet

private struct NameConfirmSheet: View {
    let playerNumber: Int
    let totalPlayers: Int
    @Binding var name: String
    let onRetake: () -> Void
    let onConfirm: () -> Void

    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConfirm: Bool { !trimmedName.isEmpty }

    var body: some View {
        VStack(spacing: 22) {
            // Capture-success badge
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.orange)
            }
            .padding(.top, 8)

            VStack(spacing: 4) {
                Text("Got you")
                    .font(.title2.bold())
                Text("Player \(playerNumber) of \(totalPlayers)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Name entry — large, centred, autofocus, submit on return
            TextField("Enter name", text: $name)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($nameFocused)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(nameFocused ? Color.orange : .clear, lineWidth: 1.5)
                )
                .padding(.horizontal, 24)
                .onSubmit {
                    if canConfirm { onConfirm() }
                }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button(action: { if canConfirm { onConfirm() } }) {
                    Text("Confirm")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(canConfirm ? Color.orange : Color.secondary.opacity(0.25))
                        )
                        .foregroundStyle(.white)
                }
                .disabled(!canConfirm)

                Button(action: onRetake) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Retake")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .padding(.top, 20)
        .onAppear {
            // Autofocus a beat after present so the keyboard animation doesn't fight the sheet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                nameFocused = true
            }
        }
    }
}

