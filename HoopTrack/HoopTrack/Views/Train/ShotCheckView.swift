// ShotCheckView.swift
// Checking the calls the tracker wasn't sure about by watching them: each
// flagged shot's few seconds of video loop while you tap Make or Miss,
// then the next one comes up. "Shot 14" from memory meant nothing; this
// shows you shot 14.

import SwiftUI
import AVFoundation

struct ShotCheckView: View {
    let session: TrainingSession
    /// Flagged shots that have a place in the video, oldest first.
    let shots: [ShotRecord]

    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject private var hapticService: HapticService
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var slow = false

    /// Shots worth checking this way: flagged, timed, with the video there.
    static func checkable(in session: TrainingSession) -> [ShotRecord] {
        guard videoURL(for: session) != nil else { return [] }
        return session.orderedShots.filter { $0.needsReview && $0.result != .pending && $0.videoTimestampSeconds != nil }
    }

    static func videoURL(for session: TrainingSession) -> URL? {
        guard let name = session.videoFileName else { return nil }
        let url = SessionRecorder.directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var shot: ShotRecord? { shots.indices.contains(index) ? shots[index] : nil }

    /// The shot's number in the session's shot list.
    private func number(of shot: ShotRecord) -> Int {
        let all = session.orderedShots.filter { $0.result != .pending }
        return (all.firstIndex { $0.id == shot.id } ?? 0) + 1
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let shot, let url = Self.videoURL(for: session) {
                LoopingClipView(url: url, around: shot.videoTimestampSeconds ?? 0, slow: slow)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)
                    .id(shot.id)
                    .accessibilityLabel("Video of shot \(number(of: shot))")
                question(shot)
            }
            Spacer(minLength: 0)
        }
        .courtBackground()
        .onAppear { if shots.isEmpty { dismiss() } }
    }

    private var topBar: some View {
        HStack {
            Text(shots.count > 1 ? "Check \(index + 1) of \(shots.count)" : "Check this shot")
                .font(.headline)
            Spacer()
            Button {
                slow.toggle()
            } label: {
                Text(slow ? "½×" : "1×")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .frame(width: 44, height: 34)
                    .background(slow ? Color.leather.opacity(0.3) : Color.panelRaised, in: Capsule())
            }
            .accessibilityLabel(slow ? "Normal speed" : "Slow motion")
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
        .foregroundStyle(.primary)
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.vertical, 12)
    }

    private func question(_ shot: ShotRecord) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Shot \(number(of: shot)) · \(shot.zone.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("The tracker said \(Text(shot.isMake ? "make" : "miss").foregroundStyle(shot.result.color).bold())")
                    .font(.title3)
            }
            .padding(.top, 20)

            HStack(spacing: 14) {
                answer(.miss, shot: shot)
                answer(.make, shot: shot)
            }
            .padding(.horizontal, Metrics.screenPadding)

            if shots.count > 1 {
                Button("Skip for now") { next() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func answer(_ result: ShotResult, shot: ShotRecord) -> some View {
        Button {
            hapticService.tap()
            dataService.updateShot(shot, result: result)
            next()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: result == .make ? "checkmark" : "xmark")
                    .font(.system(size: 28, weight: .heavy))
                Text(result == .make ? "Make" : "Miss")
                    .font(.headline)
            }
            .foregroundStyle(Color.onLeather)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(result.color, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(result == .make ? "Make" : "Miss")
        .accessibilityHint(shot.result == result ? "Keeps the call" : "Changes the call")
    }

    private func next() {
        if index + 1 < shots.count {
            index += 1
        } else {
            hapticService.milestone()
            dismiss()
        }
    }
}

/// A few seconds of the session video around one shot, on a loop, no
/// controls: from just before the release until the ball's well past the rim.
private struct LoopingClipView: UIViewRepresentable {
    let url: URL
    let around: Double
    let slow: Bool

    static let before = 1.5, after = 2.5

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url: url, from: max(0, around - Self.before), to: around + Self.after)
        view.setSlow(slow)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.setSlow(slow)
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: UIView {
        deinit {} // Keep: see "Explicit deinit" in CLAUDE.md

        override static var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var loading: Task<Void, Never>?

        func play(url: URL, from start: Double, to end: Double) {
            playerLayer.videoGravity = .resizeAspect
            playerLayer.player = player
            player.isMuted = true
            loading = Task { [weak self] in
                let asset = AVURLAsset(url: url)
                let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? end
                guard let self, !Task.isCancelled else { return }
                let stop = min(end, duration)
                let from = min(start, max(0, stop - 0.5))
                let range = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                        end: CMTime(seconds: stop, preferredTimescale: 600))
                self.looper = AVPlayerLooper(player: self.player, templateItem: AVPlayerItem(asset: asset),
                                             timeRange: range)
                self.player.play()
            }
        }

        func setSlow(_ slow: Bool) {
            player.defaultRate = slow ? 0.5 : 1
            if player.rate != 0 { player.rate = player.defaultRate }
        }

        func stop() {
            loading?.cancel()
            looper?.disableLooping()
            player.pause()
            player.removeAllItems()
        }
    }
}
