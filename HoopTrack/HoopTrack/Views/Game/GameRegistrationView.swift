// GameRegistrationView.swift
// Landscape camera preview + lock progress ring + post-capture name-entry sheet.
// Wires CameraService.framePublisher → AppearanceCaptureService and forwards
// confirmed descriptors into GameRegistrationViewModel.

import SwiftUI
import Combine
import AVFoundation

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
                    captureService.ingest(sampleBuffer: buffer)
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
}
