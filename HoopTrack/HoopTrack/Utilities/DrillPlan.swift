// DrillPlan.swift
// The steps of a named shooting drill (where to stand, how many shots),
// so the live screen can say "Spot 2 of 5 · Right wing · 3 to go" and
// tell you when to move. Progress is worked out from the attempt count
// alone, so undo just steps back.

import Foundation

nonisolated struct DrillPlan: Equatable, Sendable {

    struct Step: Equatable, Sendable {
        let spot: String
        let shots: Int
    }

    let steps: [Step]
    /// Starts again from the first step when the last is done (free-throw
    /// sets) instead of finishing.
    let repeats: Bool
    /// What a step is called on screen: "Spot" or "Set".
    let stepName: String

    var totalShots: Int { steps.reduce(0) { $0 + $1.shots } }

    /// Nil for drills without steps (timed or open drills).
    static func plan(for drill: NamedDrill) -> DrillPlan? {
        switch drill {
        case .aroundTheArc:
            return DrillPlan(steps: ["Right corner", "Right wing", "Top of the key", "Left wing", "Left corner"]
                                .map { Step(spot: $0, shots: 5) },
                             repeats: false, stepName: "Spot")
        case .midSideMid:
            return DrillPlan(steps: ["Elbow", "Baseline", "Elbow"].map { Step(spot: $0, shots: 5) },
                             repeats: false, stepName: "Spot")
        case .freethrowChallenge:
            return DrillPlan(steps: [Step(spot: "Free-throw line", shots: 10)],
                             repeats: true, stepName: "Set")
        case .fiveMinEndurance, .mikanDrill, .crossoverSeries, .twoBallDribble,
             .shuttleRun, .laneAgility, .verticalJumpTest:
            return nil
        }
    }

    /// Where the drill stands after `attempts` shots.
    func progress(after attempts: Int) -> DrillProgress {
        let total = totalShots
        let done = max(0, attempts)
        let finished = !repeats && done >= total
        let lap = repeats && total > 0 ? done / total : 0
        var into = repeats && total > 0 ? done % total : min(done, total)
        var index = 0
        while index < steps.count - 1, into >= steps[index].shots {
            into -= steps[index].shots
            index += 1
        }
        if finished { into = steps[index].shots }
        let number = repeats ? lap + 1 : index + 1
        return DrillProgress(stepNumber: number,
                             stepCount: repeats ? nil : steps.count,
                             stepName: stepName,
                             spot: steps[index].spot,
                             shotsIntoStep: into,
                             shotsInStep: steps[index].shots,
                             isFinished: finished)
    }
}

nonisolated struct DrillProgress: Equatable, Sendable {
    /// 1-based. For repeating drills, which set this is.
    let stepNumber: Int
    /// Nil when the drill repeats (no last step).
    let stepCount: Int?
    let stepName: String
    let spot: String
    let shotsIntoStep: Int
    let shotsInStep: Int
    let isFinished: Bool

    var shotsToGo: Int { max(0, shotsInStep - shotsIntoStep) }

    /// "Spot 2 of 5" / "Set 3".
    var stepLabel: String {
        if let stepCount { return "\(stepName) \(stepNumber) of \(stepCount)" }
        return "\(stepName) \(stepNumber)"
    }

    /// The live screen's line: "Spot 2 of 5 · Right wing · 3 to go".
    var line: String {
        if isFinished { return "Drill done" }
        return "\(stepLabel) · \(spot) · \(shotsToGo) to go"
    }

    /// Same place in the drill as `other` (ignoring shots within the step).
    func isSameStep(as other: DrillProgress) -> Bool {
        stepNumber == other.stepNumber && isFinished == other.isFinished
    }
}
