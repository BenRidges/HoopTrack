// LiveGameView.swift
// SP1: camera-free shell that shows the scoreboard and manual make/miss
// buttons. SP2 replaces the manual buttons with CV attribution and adds
// the killfeed + player overlays.

import SwiftUI

struct LiveGameView: View {
    @ObservedObject var viewModel: GameSessionViewModel
    let onEndGame: () -> Void

    @State private var selectedShooter: GamePlayer?

    var body: some View {
        VStack(spacing: 20) {
            scoreboard

            playerPicker

            HStack(spacing: 12) {
                manualShotButton(.miss, label: "Miss", colour: .red)
                manualShotButton(.make, label: "2PT", colour: .green, shotType: .twoPoint)
                manualShotButton(.make, label: "3PT", colour: .orange, shotType: .threePoint)
            }

            Spacer()

            Button {
                viewModel.endSession()
                onEndGame()
            } label: {
                Text("End game")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
        }
        .padding()
        .onAppear {
            selectedShooter = viewModel.session.players.first
        }
    }

    // MARK: - Subviews

    private var scoreboard: some View {
        HStack {
            VStack {
                Text("TEAM A").font(.caption).foregroundStyle(.orange)
                Text("\(viewModel.session.teamAScore)").font(.system(size: 48, weight: .black))
            }
            Spacer()
            Text("—").font(.largeTitle)
            Spacer()
            VStack {
                Text("TEAM B").font(.caption).foregroundStyle(.blue)
                Text("\(viewModel.session.teamBScore)").font(.system(size: 48, weight: .black))
            }
        }
        .padding(.horizontal)
    }

    private var playerPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shooter").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(viewModel.session.players) { player in
                        Button {
                            selectedShooter = player
                        } label: {
                            Text(player.name)
                                .font(.subheadline.bold())
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(
                                    selectedShooter?.id == player.id
                                        ? Color.orange.opacity(0.4)
                                        : Color.secondary.opacity(0.15),
                                    in: Capsule()
                                )
                        }
                    }
                }
            }
        }
    }

    private func manualShotButton(
        _ result: ShotResult,
        label: String,
        colour: Color,
        shotType: GameShotType = .twoPoint
    ) -> some View {
        Button {
            guard let shooter = selectedShooter else { return }
            viewModel.logShot(
                shooter: shooter,
                result: result,
                courtX: 0.5, courtY: 0.5,
                shotType: shotType
            )
        } label: {
            Text(label)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(colour, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
        .disabled(selectedShooter == nil)
    }
}
