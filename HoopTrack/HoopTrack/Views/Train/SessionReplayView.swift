// HoopTrack/Views/Train/SessionReplayView.swift
// Session video with a shot strip underneath: tap a shot to jump to it.
// Standard player controls, so scrubbing and AirPlay just work.

import SwiftUI
import AVKit
import AVFoundation

struct SessionReplayView: View {
    let session: TrainingSession
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var selected: ShotRecord.ID?

    private var timedShots: [ShotRecord] {
        session.orderedShots.filter { $0.videoTimestampSeconds != nil && $0.result != .pending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.title)
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Color.panelRaised, in: Circle())
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, 12)

            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ContentUnavailableView("Video unavailable",
                                           systemImage: "video.slash",
                                           description: Text("It may have been deleted to save space."))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(Color.black)

            if !timedShots.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Jump to a shot")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(timedShots.enumerated()), id: \.element.id) { index, shot in
                                Button {
                                    jump(to: shot)
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle().fill(shot.result.color).frame(width: 8, height: 8)
                                        Text("\(index + 1)")
                                            .font(.subheadline.weight(.semibold).monospacedDigit())
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(selected == shot.id ? Color.leather.opacity(0.25) : Color.panelRaised,
                                                in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Shot \(index + 1), \(shot.isMake ? "make" : "miss")")
                            }
                        }
                    }
                }
                .padding(Metrics.screenPadding)
            }
            Spacer()
        }
        .courtBackground()
        .onAppear(perform: setUp)
        .onDisappear { player?.pause() }
    }

    private func setUp() {
        guard player == nil, let name = session.videoFileName else { return }
        let url = SessionRecorder.directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let avPlayer = AVPlayer(url: url)
        player = avPlayer
        avPlayer.play()
    }

    private func jump(to shot: ShotRecord) {
        selected = shot.id
        // Start a beat before release so you see the whole shot.
        let t = max(0, (shot.videoTimestampSeconds ?? 0) - 1.0)
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
    }
}
