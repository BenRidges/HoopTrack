// HoopTrack/Auth/BiometricService.swift
import Foundation
import Combine
import LocalAuthentication

@MainActor
final class BiometricService: ObservableObject {

    enum AvailabilityStatus: Sendable, Equatable {
        case available(LABiometryType)
        case unavailable
    }

    @Published private(set) var availability: AvailabilityStatus = .unavailable

    init() { availability = computeAvailability() }

    func refresh() { availability = computeAvailability() }

    /// Prompts Face ID / Touch ID. Returns true on success, throws AuthError on failure.
    /// The reason string is shown to the user in the system prompt.
    func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw AuthError.biometricUnavailable
        }

        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            throw AuthError.biometricFailed
        }
    }

    private func computeAvailability() -> AvailabilityStatus {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return .available(context.biometryType)
        }
        return .unavailable
    }
}
