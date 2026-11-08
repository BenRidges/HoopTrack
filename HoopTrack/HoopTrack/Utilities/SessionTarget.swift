// SessionTarget.swift
// Something to chase on the live screen: your best in this drill, your
// field-goal goal, or your most makes in a session.

import Foundation

nonisolated enum SessionTarget: Equatable, Sendable {
    /// Beat this many makes (your best in this drill, or in any session).
    case makes(best: Int)
    /// Shoot at least this field-goal percentage (an active goal).
    case percent(goal: Double)

    /// Attempts before a percentage says anything.
    static let minAttemptsForPercent = 5

    /// Picks the target: a named drill races your best in that drill; a
    /// free session races your field-goal goal, else your most makes ever.
    /// Nil when there's nothing to race yet.
    static func choose(drillBest: Int?, isNamedDrill: Bool, fgGoal: Double?, mostMakes: Int) -> SessionTarget? {
        if isNamedDrill {
            guard let drillBest, drillBest > 0 else { return nil }
            return .makes(best: drillBest)
        }
        if let fgGoal, fgGoal > 0 { return .percent(goal: fgGoal) }
        return mostMakes > 0 ? .makes(best: mostMakes) : nil
    }

    func isMet(makes: Int, attempts: Int) -> Bool {
        switch self {
        case .makes(let best):
            return makes > best
        case .percent(let goal):
            guard attempts >= Self.minAttemptsForPercent else { return false }
            return Double(makes) / Double(attempts) * 100 >= goal
        }
    }

    /// The live screen's line: "Best 18 · 7 to beat", "New best",
    /// "Goal 50% · on target".
    func line(makes: Int, attempts: Int) -> String {
        switch self {
        case .makes(let best):
            if makes > best { return "New best" }
            return "Best \(best) · \(best + 1 - makes) to beat"
        case .percent(let goal):
            let goalText = "Goal \(Int(goal.rounded()))%"
            return isMet(makes: makes, attempts: attempts) ? "\(goalText) · on target" : goalText
        }
    }
}
