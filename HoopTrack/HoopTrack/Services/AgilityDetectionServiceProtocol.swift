// AgilityDetectionServiceProtocol.swift
// Abstraction for agility start/stop trigger detection.
// VolumeButtonAgilityDetectionService is the production impl.
// Tests inject a mock that fires onTrigger programmatically.

import AVFoundation

@MainActor protocol AgilityDetectionServiceProtocol: AnyObject {
    /// Called on the main actor each time the user signals start/stop (e.g., presses Vol+).
    var onTrigger: (() -> Void)? { get set }
    func startListening()
    func stopListening()
}

// MARK: - Volume Button Implementation

@MainActor final class VolumeButtonAgilityDetectionService: NSObject, AgilityDetectionServiceProtocol {

    var onTrigger: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var observation: NSKeyValueObservation?

    func startListening() {
        try? session.setCategory(.ambient)
        try? session.setActive(true)

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.onTrigger?()
            }
        }
    }

    func stopListening() {
        observation?.invalidate()
        observation = nil
        try? session.setActive(false)
    }
}
