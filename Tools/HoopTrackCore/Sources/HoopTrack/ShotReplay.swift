// ShotReplay.swift
// Offline evaluation of the shot tracker. A session recorded with "Help
// improve shot tracking" on leaves a detections.jsonl log; replaying it
// through a fresh ShotTracker (and the same hoop smoothing as the live
// pipeline) shows what a tuning change would have called, and scoring
// those calls against hand labels turns "feels better" into a number.
//
// Package-only: never compiled into the app.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated enum ShotReplay {

    struct Call: Sendable, Equatable {
        /// When the ball reached the rim (or the call was made, if it never did).
        let time: Double
        let result: ShotResult
        let confidence: Double
    }

    /// Runs `entries` (in time order) through a new tracker, then the net
    /// check (NetCheck) as the app does, unless `netCheck` is off. Logs from
    /// before net sampling have no `netActivity`, so the check never changes
    /// their calls. The hoop smoother gets every logged basket, as the app's
    /// did (`hoops(in:)`).
    static func run(_ entries: [DetectionLogEntry],
                    aspect: Double = 16.0 / 9.0,
                    tuning: ShotTracker.Tuning = ShotTracker.Tuning(),
                    netCheck useNet: Bool = true) -> [Call] {
        var tracker = ShotTracker(aspect: aspect, tuning: tuning)
        var smoother = HoopRectSmoother()
        var meter = NetMotionMeter()
        var check = NetCheck<Void>()
        var calls: [Call] = []

        func add(_ call: NetCheck<Void>.Call) {
            calls.append(Call(time: call.outcome.rimArrivalTime ?? call.outcome.lastSeenTime,
                              result: call.result, confidence: call.confidence))
        }

        for entry in entries.sorted(by: { $0.timestampSec < $1.timestampSec }) {
            let t = entry.timestampSec
            // CourtCalibrationService.updateBaskets, from the same candidates.
            if let rim = smoother.choose(from: hoops(in: entry)) {
                smoother.update(basketRect: rim, timestamp: t)
            } else {
                smoother.updateNoDetection(timestamp: t)
            }
            let hoop = smoother.state == .looking ? nil : smoother.smoothedRect

            // The app clears its meter on any frame without a net sample.
            if useNet, let activity = entry.netActivity {
                meter.record(activity, at: t)
            } else {
                meter.reset()
            }

            switch tracker.update(balls: balls(in: entry), hoop: hoop, time: t) {
            case .started:
                if let call = check.flush(meter: meter) { add(call) }
            case .resolved(let outcome):
                check.submit(outcome, context: (), now: t, meter: meter).forEach(add)
            case nil:
                if let call = check.due(now: t, meter: meter) { add(call) }
            }
        }
        if let call = check.flush(meter: meter) { add(call) }
        return calls
    }

    /// Reads a detections.jsonl file's contents, skipping unreadable lines.
    static func entries(fromJSONL text: String) -> [DetectionLogEntry] {
        text.split(whereSeparator: \.isNewline).compactMap {
            try? DetectionLogEntry.decode(jsonLine: String($0))
        }
    }

    /// The hoop candidates the app's smoother chose from on this frame:
    /// every basket the detector returned (`baskets`), most confident first.
    /// Older logs kept only the top one (`rimBox`).
    static func hoops(in entry: DetectionLogEntry) -> [CGRect] {
        entry.baskets?.compactMap { rect(Array($0.prefix(4))) }
            ?? entry.rimBox.flatMap(rect).map { [$0] } ?? []
    }

    /// The ball candidates the tracker was given on this frame (older logs:
    /// the top one only).
    static func balls(in entry: DetectionLogEntry) -> [CGRect] {
        entry.balls?.compactMap { rect(Array($0.prefix(4))) }
            ?? entry.ballBox.flatMap(rect).map { [$0] } ?? []
    }

    private static func rect(_ values: [Double]) -> CGRect? {
        guard values.count >= 4, values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}

nonisolated enum ShotEvaluation {

    /// A hand-labelled shot: roughly when the ball reached the rim.
    struct Label: Sendable, Equatable {
        let time: Double
        let result: ShotResult
    }

    struct Report: Sendable, Equatable {
        var labelled = 0
        var called = 0
        /// Calls paired with a labelled shot.
        var matched = 0
        /// Matched calls with the right result.
        var correct = 0
        var makesCalledMiss = 0
        var missesCalledMake = 0
        /// Calls with no labelled shot nearby (a dribble or pass taken for a shot).
        var phantomShots = 0
        /// Labelled shots the tracker never called.
        var missedShots = 0

        var detectionRate: Double { labelled > 0 ? Double(matched) / Double(labelled) : 0 }
        var callAccuracy: Double { matched > 0 ? Double(correct) / Double(matched) : 0 }

        var summary: String {
            func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
            return """
            Shots labelled: \(labelled), called: \(called)
            Detected: \(matched)/\(labelled) (\(pct(detectionRate)))
            Calls right: \(correct)/\(matched) (\(pct(callAccuracy)))
              makes called miss: \(makesCalledMiss)
              misses called make: \(missesCalledMake)
            Phantom shots: \(phantomShots)
            Missed shots: \(missedShots)
            """
        }
    }

    /// Pairs calls and labels closest-first, each used at most once, when
    /// they're within `tolerance` seconds of each other.
    static func score(calls: [ShotReplay.Call], labels: [Label], tolerance: Double = 1.5) -> Report {
        var pairs: [(call: Int, label: Int, gap: Double)] = []
        for (c, call) in calls.enumerated() {
            for (l, label) in labels.enumerated() {
                let gap = abs(call.time - label.time)
                if gap <= tolerance { pairs.append((c, l, gap)) }
            }
        }
        pairs.sort { $0.gap < $1.gap }

        var report = Report(labelled: labels.count, called: calls.count)
        var usedCalls = Set<Int>(), usedLabels = Set<Int>()
        for pair in pairs where !usedCalls.contains(pair.call) && !usedLabels.contains(pair.label) {
            usedCalls.insert(pair.call)
            usedLabels.insert(pair.label)
            report.matched += 1
            let called = calls[pair.call].result, truth = labels[pair.label].result
            if called == truth {
                report.correct += 1
            } else if truth == .make {
                report.makesCalledMiss += 1
            } else {
                report.missesCalledMake += 1
            }
        }
        report.phantomShots = calls.count - usedCalls.count
        report.missedShots = labels.count - usedLabels.count
        return report
    }

    /// Labels from CSV lines of `seconds,result` — result is make/miss
    /// (or m / x). Blank lines, `#` comments and a header row are ignored.
    static func labels(fromCSV text: String) -> [Label] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count >= 2, let time = Double(parts[0]) else { return nil }
            switch parts[1] {
            case "make", "m", "1":  return Label(time: time, result: .make)
            case "miss", "x", "0":  return Label(time: time, result: .miss)
            default:                return nil
            }
        }
    }
}
