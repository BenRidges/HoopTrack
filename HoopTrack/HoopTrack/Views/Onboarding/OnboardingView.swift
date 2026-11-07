// OnboardingView.swift
// Two steps: who you are, and how to set the phone up. Permissions are
// asked for when they're needed (camera here, because the next thing you
// do is shoot; notifications only when you turn on a reminder).
//
// The old five-page flow saved the name to UserDefaults and only applied
// it if the profile name was empty — it never was ("Player"), so names
// entered during onboarding were silently dropped.

import SwiftUI
import UIKit
import AVFoundation

struct OnboardingView: View {
    let onComplete: () -> Void

    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject private var cameraService: CameraService
    @State private var step = 0
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            Color.court.ignoresSafeArea()
            if step == 0 {
                welcome.transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
            } else {
                setup.transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: step)
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            HalfCourtShape(sidelines: false)
                .stroke(Color.leather.opacity(0.35), lineWidth: 2)
                .aspectRatio(CourtGeometry.widthFt / CourtGeometry.depthFt, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 300)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text("HOOPTRACK")
                    .font(.score(64))
                Text("Prop up your phone, shoot, and see every make, miss and spot you shot from.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                Text("What should we call you?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Your name", text: $name)
                    .font(.title3)
                    .textContentType(.givenName)
                    .submitLabel(.continue)
                    .focused($nameFocused)
                    .onSubmit(next)
                    .padding(16)
                    .background(Color.panel, in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
            }

            Button("Continue", action: next)
                .buttonStyle(.primary)
                .padding(.top, 16)
        }
        .padding(Metrics.screenPadding)
    }

    private func next() {
        nameFocused = false
        dataService.setPlayerName(name)
        step = 1
    }

    // MARK: - Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set up once, then just shoot")
                    .font(.largeTitle.bold())
                Text("Tracking works best from behind you, looking at the hoop.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)

            VStack(alignment: .leading, spacing: 22) {
                tip(number: 1, title: "Phone sideways on a stand",
                    detail: "A tripod, a water bottle, a bag — about chest height, four big steps (3 m) behind where you shoot.")
                tip(number: 2, title: "Whole rim in the picture",
                    detail: "You'll see brackets lock onto the hoop when it's found.")
                tip(number: 3, title: "Shoot",
                    detail: "Makes and misses log themselves. Tap Make or Miss any time to fix a call.")
            }

            Spacer()

            VStack(spacing: 12) {
                if cameraService.permissionStatus == .notDetermined {
                    Button("Allow camera and start") {
                        Task {
                            await cameraService.requestPermission()
                            onComplete()
                        }
                    }
                    .buttonStyle(.primary)
                    Button("Not now", action: onComplete)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Start", action: onComplete)
                        .buttonStyle(.primary)
                }
            }
        }
        .padding(Metrics.screenPadding)
    }

    private func tip(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .font(.score(26))
                .foregroundStyle(Color.onLeather)
                .frame(width: 36, height: 36)
                .background(Color.leather, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
