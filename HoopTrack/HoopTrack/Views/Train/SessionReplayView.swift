// HoopTrack/Views/Train/SessionReplayView.swift
// Full-screen video replay with shot timeline markers and per-shot Shot Science overlay.

import SwiftUI
import AVKit

struct SessionReplayView: View {
    let session: TrainingSession
    @Environment(\.dismiss) private var dismiss

    @State private var player:         AVPlayer?
    @State private var currentTimeSec: Double  = 0
    @State private var selectedShot:   ShotRecord? = nil
    @State private var timeObserver:   Any?
    @State private var duration:       Double  = 0

    private var timedShots: [ShotRecord] {
        session.shots
            .filter { $0.videoTimestampSeconds != nil && $0.result != .pending }
            .sorted { $0.sequenceIndex < $1.sequenceIndex }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayerView(player: player)
                    .ignoresSafeArea()
            }

            VStack {
                Spacer()
                if let shot = selectedShot {
                    ShotScienceCard(shot: shot)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 80)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35), value: selectedShot?.id)

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(16)
                    }
                    Spacer()
                }

                Spacer()

                shotTimeline
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
        }
        .statusBarHidden(true)
        .onAppear  { setupPlayer() }
        .onDisappear { teardownPlayer() }
    }

    private var shotTimeline: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(height: 4)

                Capsule()
                    .fill(.white.opacity(0.8))
                    .frame(width: progressWidth(in: geo.size.width, for: currentTimeSec),
                           height: 4)

                ForEach(timedShots) { shot in
                    Circle()
                        .fill(shot.isMake ? .green : .red)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle().stroke(
                                selectedShot?.id == shot.id ? Color.white : .clear,
                                lineWidth: 2
                            )
                        )
                        .offset(
                            x: progressWidth(in: geo.size.width,
                                             for: shot.videoTimestampSeconds!) - 7,
                            y: -5
                        )
                        .onTapGesture {
                            let isSame = selectedShot?.id == shot.id
                            selectedShot = isSame ? nil : shot
                            if !isSame {
                                player?.seek(
                                    to: CMTime(seconds: shot.videoTimestampSeconds!,
                                               preferredTimescale: 600),
                                    toleranceBefore: .zero,
                                    toleranceAfter:  .zero
                                )
                            }
                        }
                }
            }
            .frame(height: 20)
        }
        .frame(height: 20)
        .background(.ultraThinMaterial.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 8)
    }

    private func progressWidth(in totalWidth: CGFloat, for seconds: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(seconds / duration) * totalWidth
    }

    private func setupPlayer() {
        guard let fileName = session.videoFileName else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url  = docs.appendingPathComponent("Sessions/\(fileName)")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let avPlayer = AVPlayer(url: url)

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak avPlayer] time in
            currentTimeSec = CMTimeGetSeconds(time)
            if let d = avPlayer?.currentItem?.duration, d.isNumeric {
                duration = CMTimeGetSeconds(d)
            }
        }

        player = avPlayer
        avPlayer.play()
    }

    private func teardownPlayer() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        player?.pause()
        player = nil
    }
}

private struct VideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player               = player
        vc.showsPlaybackControls = false
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        vc.player = player
    }
}
