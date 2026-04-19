// GameConsentView.swift
// Plain-language consent before appearance capture. Required before any
// camera activation for Game Mode registration — see master plan §6.3.

import SwiftUI

struct GameConsentView: View {
    let format: GameFormat
    let gameType: GameType
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange.gradient)
                .padding(.top, 40)

            Text("Quick heads-up")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 16) {
                bullet(
                    systemImage: "camera",
                    title: "We'll capture an appearance profile",
                    body: "For each player, HoopTrack records a short clothing-colour profile so the camera can tell who's shooting."
                )
                bullet(
                    systemImage: "lock.shield",
                    title: "It stays on this phone",
                    body: "Profiles are stored only for this game and deleted automatically when the game ends. Nothing is uploaded."
                )
                bullet(
                    systemImage: "person.crop.circle.badge.checkmark",
                    title: "Consent from everyone",
                    body: "Only register players who've agreed to being on camera."
                )
            }
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                Button(action: onContinue) {
                    Text("I understand — continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.orange, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                Button("Cancel", action: onCancel)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .accessibilityElement(children: .contain)
    }

    private func bullet(systemImage: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
