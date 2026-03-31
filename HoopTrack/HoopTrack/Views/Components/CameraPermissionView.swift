// CameraPermissionView.swift
// Shown when camera access has been denied or not yet requested.
// Provides context and a button to open Settings.

import SwiftUI
import AVFoundation

struct CameraPermissionView: View {

    @EnvironmentObject var cameraService: CameraService
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Camera Access Required")
                    .font(.title2.bold())

                Text("HoopTrack uses your camera to automatically track shots, analyse your form, and map your shooting locations in real time. No footage ever leaves your device.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            switch cameraService.permissionStatus {

            case .notDetermined:
                Button {
                    isRequesting = true
                    Task {
                        await cameraService.requestPermission()
                        isRequesting = false
                    }
                } label: {
                    Label("Allow Camera Access", systemImage: "camera")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isRequesting)

            case .denied, .restricted:
                VStack(spacing: 12) {
                    Text("Camera access was denied.")
                        .foregroundStyle(.red)
                        .font(.subheadline)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                            .frame(maxWidth: 280)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }

            default:
                EmptyView()
            }

            Spacer()
        }
        .padding()
    }
}

#Preview {
    CameraPermissionView()
        .environmentObject(CameraService())
}
