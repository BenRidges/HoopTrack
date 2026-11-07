// Benchmark.swift
// Scores a simulated recording exactly the way shot-eval scores a real
// one — ShotReplay.run over the log, ShotEvaluation.score against the
// labels — and adds what shot-eval doesn't print: phantom shots per
// minute, how many wrong calls were flagged for review, and the timing
// error of matched calls.

import Foundation
@testable import HoopTrack

struct ScenarioScore: Sendable {
    let name: String
    let summary: String
    let labelsShots: Bool
    let report: ShotEvaluation.Report
    let footageMinutes: Double
    /// Matched calls with the wrong result, plus phantom calls.
    let wrongCalls: Int
    /// …of which flagged for review (confidence below HoopTrack.CV.lowConfidence).
    let wrongFlagged: Int
    /// Right calls that were flagged anyway (asks the user for nothing).
    let rightFlagged: Int
    /// Mean |call time − label time| over matched calls, seconds.
    let meanTimeError: Double?
    /// Calls the live pipeline published that the replay didn't reproduce.
    let liveDisagreements: Int
    /// Per true kind: shots, detected, called right.
    let byKind: [ShotKind: (shots: Int, detected: Int, right: Int)]

    var phantomsPerMinute: Double { footageMinutes > 0 ? Double(report.phantomShots) / footageMinutes : 0 }
    /// Labelled shots called right, over all labelled shots.
    var endToEnd: Double { report.labelled > 0 ? Double(report.correct) / Double(report.labelled) : 0 }
}

struct Pairing: Sendable {
    var call: Int
    var label: Int
}

enum Benchmark {

    /// The calls shot-eval would make on this run's log.
    static func calls(_ run: SimulationRun, netCheck: Bool = true) -> [ShotReplay.Call] {
        ShotReplay.run(run.entries, netCheck: netCheck)
    }

    /// ShotEvaluation.score's pairing (closest first, each used once,
    /// within `tolerance`), returning the pairs themselves.
    static func pairs(calls: [ShotReplay.Call], labels: [ShotEvaluation.Label], tolerance: Double = 1.5) -> [Pairing] {
        var candidates: [(call: Int, label: Int, gap: Double)] = []
        for (c, call) in calls.enumerated() {
            for (l, label) in labels.enumerated() {
                let gap = abs(call.time - label.time)
                if gap <= tolerance { candidates.append((c, l, gap)) }
            }
        }
        candidates.sort { $0.gap < $1.gap }
        var usedCalls = Set<Int>(), usedLabels = Set<Int>()
        var out: [Pairing] = []
        for p in candidates where !usedCalls.contains(p.call) && !usedLabels.contains(p.label) {
            usedCalls.insert(p.call)
            usedLabels.insert(p.label)
            out.append(Pairing(call: p.call, label: p.label))
        }
        return out
    }

    static func score(_ run: SimulationRun, calls: [ShotReplay.Call]) -> ScenarioScore {
        let labels = run.labels
        let report = ShotEvaluation.score(calls: calls, labels: labels)
        let matched = pairs(calls: calls, labels: labels)
        let low = HoopTrack.CV.lowConfidence
        var wrong = 0, wrongFlagged = 0, rightFlagged = 0
        var timeError = 0.0
        var byKind: [ShotKind: (shots: Int, detected: Int, right: Int)] = [:]
        for shot in run.shots {
            var entry = byKind[shot.kind] ?? (0, 0, 0)
            entry.shots += 1
            byKind[shot.kind] = entry
        }
        for p in matched {
            let call = calls[p.call], label = labels[p.label]
            timeError += abs(call.time - label.time)
            let kind = run.shots[p.label].kind
            byKind[kind]?.detected += 1
            if call.result == label.result {
                byKind[kind]?.right += 1
                if call.confidence < low { rightFlagged += 1 }
            } else {
                wrong += 1
                if call.confidence < low { wrongFlagged += 1 }
            }
        }
        let paired = Set(matched.map(\.call))
        for (c, call) in calls.enumerated() where !paired.contains(c) {
            wrong += 1
            if call.confidence < low { wrongFlagged += 1 }
        }
        let live = disagreements(run.liveCalls, calls)
        return ScenarioScore(name: run.scenario.name, summary: run.scenario.summary,
                             labelsShots: run.scenario.labelsShots, report: report,
                             footageMinutes: run.footageSeconds / 60, wrongCalls: wrong, wrongFlagged: wrongFlagged,
                             rightFlagged: rightFlagged,
                             meanTimeError: matched.isEmpty ? nil : timeError / Double(matched.count),
                             liveDisagreements: live, byKind: byKind)
    }

    /// Calls in one list with no call of the same result within 0.3 s in
    /// the other (small timing shifts from a slightly different rim box
    /// don't count).
    static func disagreements(_ a: [ShotReplay.Call], _ b: [ShotReplay.Call]) -> Int {
        let close = pairs(calls: a, labels: b.map { ShotEvaluation.Label(time: $0.time, result: $0.result) }, tolerance: 0.3)
        let agreeing = close.filter { a[$0.call].result == b[$0.label].result }.count
        return a.count + b.count - 2 * agreeing
    }

    // MARK: Printing

    static let header = """
    scenario          shots   det%  right%    ok%  mk>ms  ms>mk  phantom   /min  flag%  dt ms
    """

    static func row(_ s: ScenarioScore) -> String {
        func pct(_ v: Double) -> String { String(format: "%6.1f", v * 100) }
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
        let r = s.report
        let flag = s.wrongCalls > 0 ? String(format: "%5.0f", 100 * Double(s.wrongFlagged) / Double(s.wrongCalls)) : "    -"
        let dt = s.meanTimeError.map { String(format: "%6.0f", $0 * 1000) } ?? "     -"
        if !s.labelsShots {
            return pad(s.name, 17) + lpad("-", 6) + lpad("-", 7) + lpad("-", 8) + lpad("-", 7) + lpad("-", 7) + lpad("-", 7)
                + lpad(String(r.phantomShots), 9) + String(format: "%7.2f", s.phantomsPerMinute) + "  " + flag + "  " + dt
        }
        return pad(s.name, 17) + lpad(String(r.labelled), 6) + " " + pct(r.detectionRate) + "  " + pct(r.callAccuracy)
            + " " + pct(s.endToEnd) + lpad(String(r.makesCalledMiss), 7) + lpad(String(r.missesCalledMake), 7)
            + lpad(String(r.phantomShots), 9) + String(format: "%7.2f", s.phantomsPerMinute) + "  " + flag + "  " + dt
    }

    static let legend = """
    det%     labelled shots the tracker called at all (within 1.5 s of the label)
    right%   of those, the right result          ok%  right calls / all shots
    mk>ms    makes called misses                 ms>mk  misses called makes
    phantom  calls with no shot nearby (/min of footage)
    flag%    wrong calls (wrong result or phantom) flagged "Check" (confidence < \(HoopTrack.CV.lowConfidence))
    dt ms    mean |call time − label time| for matched calls (label = ball reaches the rim)
    """

    /// NetMotionMeter.swing after each labelled shot's arrival, replayed from
    /// the log as ShotReplay does: how well the simulated net separates makes
    /// from misses.
    static func netSwings(_ run: SimulationRun) -> (makes: [Double], misses: [Double], baseline: [Double]) {
        var meter = NetMotionMeter()
        var makes: [Double] = [], misses: [Double] = [], baseline: [Double] = []
        let shots = run.shots.sorted { $0.labelTime < $1.labelTime }
        var next = 0
        for entry in run.entries {
            if let a = entry.netActivity { meter.record(a, at: entry.timestampSec); baseline.append(a) } else { meter.reset() }
            while next < shots.count, entry.timestampSec >= NetMotionMeter.decisionTime(arrival: shots[next].labelTime) {
                if let s = meter.swing(after: shots[next].labelTime) {
                    if shots[next].result == .make { makes.append(s) } else { misses.append(s) }
                }
                next += 1
            }
        }
        return (makes, misses, baseline)
    }

    static func netSummary(_ run: SimulationRun) -> String {
        let (makes, misses, baseline) = netSwings(run)
        func q(_ v: [Double], _ p: Double) -> Double {
            guard !v.isEmpty else { return .nan }
            let s = v.sorted()
            return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
        }
        func describe(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "none" }
            let strong = Double(v.filter { $0 >= ShotEvidence.strongSwing }.count) / Double(v.count) * 100
            let quiet = Double(v.filter { $0 <= ShotEvidence.quietSwing }.count) / Double(v.count) * 100
            return String(format: "n=%d p10 %.1f median %.1f p90 %.1f (≥%.0f: %.0f%%, ≤%.1f: %.0f%%)", v.count, q(v, 0.1), q(v, 0.5),
                          q(v, 0.9), ShotEvidence.strongSwing, strong, ShotEvidence.quietSwing, quiet)
        }
        return "    net swing after makes: \(describe(makes))\n    net swing after misses: \(describe(misses))\n"
            + String(format: "    net activity per frame: median %.4f, p90 %.4f", q(baseline, 0.5), q(baseline, 0.9))
    }

    static func kindBreakdown(_ s: ScenarioScore) -> String {
        let parts = ShotKind.allCases.compactMap { k -> String? in
            guard let e = s.byKind[k], e.shots > 0 else { return nil }
            return "\(k.slug) \(e.right)/\(e.shots)"
        }
        return "    by kind (right/shots): " + parts.joined(separator: ", ")
    }
}
