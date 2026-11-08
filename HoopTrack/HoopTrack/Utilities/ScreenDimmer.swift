// ScreenDimmer.swift
// Turns the screen right down during a shooting session once it hasn't
// been touched for a while: the phone sits on a stand for half an hour
// with the camera, the detector and the screen all running, and the screen
// is the one nobody's looking at. Any touch brings it back (and still does
// whatever it touched). The camera and tracking don't change.
//
// Brightness is a system setting that outlives the app, so it's put back
// whenever the session ends or the app leaves the foreground.

import UIKit
import UIKit.UIGestureRecognizerSubclass

@MainActor
final class ScreenDimmer {
    deinit {} // Keep: see "Explicit deinit" in CLAUDE.md

    /// How long without a touch before dimming.
    var delay: Duration = .seconds(20)
    private static let dimLevel: CGFloat = 0.06

    private var isRunning = false
    private var original: CGFloat?
    private var timer: Task<Void, Never>?
    private var fade: Task<Void, Never>?
    private var recognizers: [(UIWindow, UIGestureRecognizer)] = []
    private var observers: [NSObjectProtocol] = []

    var isDimmed: Bool { original != nil }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        for window in Self.windows {
            let watcher = TouchWatcher { [weak self] in self?.wake() }
            window.addGestureRecognizer(watcher)
            recognizers.append((window, watcher))
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restore(rearm: false) }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            },
        ]
        arm()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        restore(rearm: false)
        recognizers.forEach { window, recognizer in window.removeGestureRecognizer(recognizer) }
        recognizers = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    /// Back to full brightness, and the countdown starts again.
    func wake() {
        restore(rearm: true)
    }

    // MARK: - Private

    private func arm() {
        timer?.cancel()
        guard isRunning else { return }
        timer = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dim()
        }
    }

    private func dim() {
        guard isRunning, original == nil, let screen = Self.screen else { return }
        let from = screen.brightness
        guard from > Self.dimLevel else { return }
        original = from
        ramp(screen, from: from, to: Self.dimLevel, over: 0.8)
    }

    private func restore(rearm: Bool) {
        timer?.cancel()
        if let original, let screen = Self.screen {
            fade?.cancel()
            screen.brightness = original
        }
        original = nil
        if rearm { arm() }
    }

    /// Brightness jumps when set; step it so dimming isn't a flash.
    private func ramp(_ screen: UIScreen, from: CGFloat, to: CGFloat, over seconds: Double) {
        fade?.cancel()
        fade = Task { [weak self] in
            let steps = 12
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                guard !Task.isCancelled, self?.isDimmed == true else { return }
                screen.brightness = from + (to - from) * CGFloat(step) / CGFloat(steps)
            }
        }
    }

    private static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static var screen: UIScreen? { scene?.screen }
    private static var windows: [UIWindow] { scene?.windows ?? [] }
}

/// Sees every touch in a window without taking part: it never recognises,
/// so buttons and gestures under the finger work as usual.
private final class TouchWatcher: UIGestureRecognizer {
    deinit {} // Keep: see "Explicit deinit" in CLAUDE.md

    private let onTouch: () -> Void

    init(onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
