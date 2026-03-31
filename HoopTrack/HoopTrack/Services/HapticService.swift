// HapticService.swift
// Wraps UIImpactFeedbackGenerator and UINotificationFeedbackGenerator.
// Call from any ViewModel; never call UIKit haptic APIs directly from Views.

import UIKit
import Combine

@MainActor
final class HapticService: ObservableObject {

    // Pre-warmed generators for lower latency during live sessions.
    private let lightImpact   = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact  = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact   = UIImpactFeedbackGenerator(style: .heavy)
    private let notification  = UINotificationFeedbackGenerator()

    init() {
        // Pre-warm all generators so first call is snappy.
        lightImpact.prepare()
        mediumImpact.prepare()
        heavyImpact.prepare()
        notification.prepare()
    }

    // MARK: - Shot Events

    /// Light tap — shot confirmed (make or miss).
    func shotDetected() {
        lightImpact.impactOccurred()
        lightImpact.prepare()
    }

    /// Satisfying thud — make confirmed.
    func makeMade() {
        mediumImpact.impactOccurred(intensity: 1.0)
        mediumImpact.prepare()
    }

    /// Subtle pulse — miss confirmed.
    func missMade() {
        lightImpact.impactOccurred(intensity: 0.5)
        lightImpact.prepare()
    }

    // MARK: - Milestones

    /// Celebratory buzz — streak, personal record, goal achieved.
    func milestone() {
        notification.notificationOccurred(.success)
        notification.prepare()
    }

    /// Error feedback — invalid action or correction rejected.
    func error() {
        notification.notificationOccurred(.error)
        notification.prepare()
    }

    // MARK: - UI Interaction

    /// Standard tap feedback for buttons and toggles.
    func tap() {
        lightImpact.impactOccurred()
        lightImpact.prepare()
    }

    /// Heavy press — long-press "End Session" confirmation.
    func longPress() {
        heavyImpact.impactOccurred()
        heavyImpact.prepare()
    }
}
