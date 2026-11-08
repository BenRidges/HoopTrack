// LiveSessionOverlays.swift
// The live screen's full-screen moments, kept apart from LiveSessionView so
// they can be drawn on their own (ScreenSnapshotTests): paused, and the
// still-shooting question after a long break.

import SwiftUI

/// The player paused: the picture dims and waits.
struct LivePausedOverlay: View {
    var isEnding = false
    let onResume: () -> Void
    let onEnd: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("Paused")
                    .font(.score(56))
                    .foregroundStyle(.white)
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.primary)
                .frame(width: 220)
                HoldToEndButton(width: 220, height: 48, isBusy: isEnding, onConfirm: onEnd)
            }
        }
    }
}

/// Paused a long time: is the session over?
struct StillShootingCard: View {
    let onEnd: () -> Void
    let onKeepGoing: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Still shooting?")
                    .font(.score(44))
                Text("Nobody's taken a shot for a while. The session ends and saves itself in a few minutes.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("End session", action: onEnd)
                        .buttonStyle(.secondary)
                    Button("Keep going", action: onKeepGoing)
                        .buttonStyle(.primary)
                }
                .frame(maxWidth: 340)
                .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 440)
            .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}
