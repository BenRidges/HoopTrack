// Phase 7 — Security
import Foundation

/// Pure functions for validating sensor values and user-provided strings
/// before they are persisted or sent to any API.
nonisolated enum InputValidator {

    // MARK: - Sensor ranges

    /// Release angle in degrees. Vision body-pose values stay within 0–90°.
    static func isValidReleaseAngle(_ degrees: Double) -> Bool {
        guard degrees.isFinite else { return false }
        return (0.0...90.0).contains(degrees)
    }

    /// Vertical jump height in centimetres. Human range 0–120 cm.
    static func isValidJumpHeight(_ cm: Double) -> Bool {
        guard cm.isFinite else { return false }
        return (0.0...120.0).contains(cm)
    }

    /// Court coordinate. Must be a normalised 0–1 half-court fraction.
    static func isValidCourtCoordinate(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        return (0.0...1.0).contains(value)
    }

    // MARK: - String inputs

    /// Trims whitespace and control characters from a profile name.
    /// Returns nil if the result is empty or exceeds 50 characters.
    static func sanitisedProfileName(_ raw: String) -> String? {
        // Strip Unicode control characters (categories Cc, Cf)
        let stripped = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.union(.illegalCharacters).contains($0) }
            .reduce("") { $0 + String($1) }

        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 50 else { return nil }
        return trimmed
    }
}
