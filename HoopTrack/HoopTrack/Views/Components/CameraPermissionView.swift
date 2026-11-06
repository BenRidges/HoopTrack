// CameraPermissionView.swift
// Shown in place of the camera when access hasn't been granted.

import SwiftUI
import UIKit
import AVFoundation

struct CameraPermissionView: View {
    var compact = false
    @EnvironmentObject private var cameraService: CameraService
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: compact ? 28 : 40, weight: .semibold))
                .foregroundStyle(Color.leather)
            Text("Camera access is off")
                .font(compact ? .headline : .title3.bold())
            Text(cameraService.permissionStatus == .denied
                 ? "Turn it on in Settings to track shots automatically. You can still score by hand."
                 : "HoopTrack needs the camera to see the ball and the hoop. Video stays on this phone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(cameraService.permissionStatus == .denied ? "Open Settings" : "Allow camera") {
                if cameraService.permissionStatus == .denied {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } else {
                    Task { await cameraService.requestPermission() }
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.leather)
            .padding(.top, 4)
        }
        .padding(24)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { cameraService.refreshPermission() }
        }
    }
}
