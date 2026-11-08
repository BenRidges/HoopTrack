// SessionAnnouncer.swift
// Calls each shot out loud during a shooting session, for a player 3 m
// from a phone on a stand: no reading the screen, no feeling a buzz.
//
//   Voice   "Make. 7 for 10." Setup tips, drill steps and results are
//           spoken too.
//   Sounds  a swish for a make, a clank for a miss, a chime for the rest.
//   Off     silent.
//
// With VoiceOver running the words go to VoiceOver instead (two voices at
// once would talk over each other); sounds still play.
//
// The audio session is only active while something is playing, so music
// from another app ducks for a call and comes straight back. Playback
// ignores the ring/silent switch: whoever turned calls on wants to hear
// them. Sounds are made here rather than shipped as files.

import AVFoundation
import Combine
import UIKit

/// What a shooting session tells the player. SessionAnnouncer in the app;
/// tests record the calls instead.
@MainActor protocol SessionAnnouncing: AnyObject {
    /// A new session starts with this mode.
    func begin(mode: ShotCallMode)
    /// The tracker's (or a tap's) call. `corrected`: a tap changed it.
    func shot(_ result: ShotResult, makes: Int, attempts: Int, corrected: Bool)
    /// A tip, a drill step or a result, after any call in progress.
    func say(_ text: String)
    /// The session is over. What's still being said is finished.
    func end()
}

@MainActor
final class SessionAnnouncer: NSObject, ObservableObject, SessionAnnouncing, AVSpeechSynthesizerDelegate {
    deinit {} // Keep: see "Explicit deinit" in CLAUDE.md

    private(set) var mode: ShotCallMode = .off
    private let synthesizer = AVSpeechSynthesizer()
    private lazy var voice: AVSpeechSynthesisVoice? = Self.bestVoice()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineReady = false
    private var audioActive = false
    private var release: Task<Void, Never>?
    private var lastVoiceOverCall = Date.distantPast

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - SessionAnnouncing

    func begin(mode: ShotCallMode) {
        self.mode = mode
    }

    func shot(_ result: ShotResult, makes: Int, attempts: Int, corrected: Bool) {
        let phrase = Self.shotPhrase(result, makes: makes, attempts: attempts, corrected: corrected)
        if UIAccessibility.isVoiceOverRunning {
            // VoiceOver announcements queue up; one every 2 s at most, so a
            // quick run of shots doesn't stack a backlog (corrections always).
            if corrected || Date.now.timeIntervalSince(lastVoiceOverCall) >= 2 {
                lastVoiceOverCall = .now
                UIAccessibility.post(notification: .announcement, argument: phrase)
            }
            if mode == .sounds { play(result == .make ? Self.swish : Self.clank) }
            return
        }
        switch mode {
        case .voice:  speak(phrase, interrupting: true)
        case .sounds: play(result == .make ? Self.swish : Self.clank)
        case .off:    break
        }
    }

    func say(_ text: String) {
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
            return
        }
        switch mode {
        case .voice:  speak(text, interrupting: false)
        case .sounds: play(Self.chime)
        case .off:    break
        }
    }

    func end() {
        mode = .off
        releaseSoon()
    }

    // MARK: - Words

    /// "Make. 7 for 10." / "Changed to miss. 6 for 10."
    nonisolated static func shotPhrase(_ result: ShotResult, makes: Int, attempts: Int,
                                       corrected: Bool) -> String {
        let word = result == .make ? "make" : "miss"
        let call = corrected ? "Changed to \(word)." : "\(word.capitalized)."
        return "\(call) \(makes) for \(attempts)."
    }

    private func speak(_ text: String, interrupting: Bool) {
        beginAudio()
        // The latest score is the one that matters: a call cuts off the
        // one before rather than queueing behind it.
        if interrupting, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
    }

    /// The device language's best installed voice, skipping novelty and
    /// personal voices.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == language
                && !$0.voiceTraits.contains(.isNoveltyVoice)
                && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.releaseSoon() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.releaseSoon() }
    }

    // MARK: - Sounds

    private func play(_ buffer: AVAudioPCMBuffer?) {
        guard let buffer else { return }
        beginAudio()
        if !engineReady {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            engineReady = true
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        releaseSoon(after: Double(buffer.frameLength) / buffer.format.sampleRate + 0.5)
    }

    private static let sampleRate = 44_100.0

    /// A make: a soft net swish with a bright ring on top.
    private static let swish: AVAudioPCMBuffer? = buffer(seconds: 0.42) { t, noise in
        let body: Double = noise * (1 - exp(-t / 0.025)) * exp(-t / 0.11) * 0.55
        guard t > 0.05 else { return body }
        let tone: Double = sin(2 * .pi * 1318.5 * t) + 0.5 * sin(2 * .pi * 1975.5 * t)
        return body + tone * exp(-(t - 0.05) / 0.12) * 0.16
    }

    /// A miss: a short metallic clank.
    private static let clank: AVAudioPCMBuffer? = buffer(seconds: 0.36) { t, noise in
        let partials: [(Double, Double)] = [(392, 1), (1046, 0.7), (1682, 0.45), (2513, 0.3)]
        let ring: Double = partials.reduce(0.0) { $0 + $1.1 * sin(2 * .pi * $1.0 * t) }
        let metal: Double = ring * exp(-t / 0.075) * 0.24
        let hit: Double = noise * exp(-t / 0.008) * 0.5
        return metal + hit
    }

    /// Anything else: two rising notes.
    private static let chime: AVAudioPCMBuffer? = buffer(seconds: 0.5) { t, _ in
        let first: Double = t < 0.16 ? sin(2 * .pi * 784 * t) * exp(-t / 0.09) : 0
        let second: Double = t >= 0.14 ? sin(2 * .pi * 1046.5 * t) * exp(-(t - 0.14) / 0.14) : 0
        return (first + second) * 0.3
    }

    /// A mono buffer from `sample(t, noise)`, where `noise` is white noise
    /// put through a band-pass around 4 kHz (a net's hiss, not a radio's).
    private static func buffer(seconds: Double,
                               _ sample: (_ t: Double, _ noise: Double) -> Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let count = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = count
        // Two-pole resonator (RBJ band-pass, Q ≈ 1.2).
        let w = 2 * Double.pi * 4000 / sampleRate, alpha = sin(w) / (2 * 1.2)
        let b0 = alpha, a0 = 1 + alpha, a1 = -2 * cos(w), a2 = 1 - alpha
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var seed: UInt32 = 0x9E37_79B9
        for i in 0..<Int(count) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Double(seed >> 8) / Double(1 << 24) * 2 - 1
            let y = (b0 * white - b0 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = white; y2 = y1; y1 = y
            let t = Double(i) / sampleRate
            // A 4 ms fade out so nothing ends on a click.
            let fade = min(1, (seconds - t) / 0.004)
            data[i] = Float(max(-1, min(1, sample(t, y * 2.2) * fade)))
        }
        return buffer
    }

    // MARK: - Audio session

    private func beginAudio() {
        release?.cancel()
        guard !audioActive else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt,
                                 options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        audioActive = true
    }

    /// Lets other apps' audio back up once nothing has played for a moment.
    private func releaseSoon(after delay: Double = 0.8) {
        release?.cancel()
        release = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.audioActive, !self.synthesizer.isSpeaking else { return }
            self.engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.audioActive = false
        }
    }
}
