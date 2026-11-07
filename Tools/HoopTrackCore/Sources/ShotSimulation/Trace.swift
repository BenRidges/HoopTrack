// Trace.swift
// "What did the tracker do?" for every shot it got wrong. Replays the log
// exactly as ShotReplay.run does (a test holds the two to the same calls),
// recording the tracker's state each frame, then lines that up with the
// truth: where the ball really was, why the detector missed it, which box
// the tracker followed, where it crossed the rim line, and how the net
// check settled the call.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import HoopTrack

struct TraceFrame: Sendable {
    let time: Double
    let hoop: CGRect?
    let tracking: Bool
    /// The tracker's shot ball after this frame (nil between shots).
    let shotBall: CGRect?
    let locked: CGRect?
    let event: ShotTracker.Event?
}

struct TraceDecision: Sendable {
    let call: ShotReplay.Call
    let outcome: ShotTracker.Outcome
    /// Net swing the check used (nil = no footage, or a net that doesn't respond).
    let swing: Double?
    let publishedAt: Double
}

struct TraceReplay: Sendable {
    var frames: [TraceFrame] = []
    var decisions: [TraceDecision] = []
    var calls: [ShotReplay.Call] { decisions.map(\.call) }

    /// ShotReplay.run, instrumented. Must stay line-for-line equivalent.
    static func run(_ entries: [DetectionLogEntry], aspect: Double = 16.0 / 9.0,
                    tuning: ShotTracker.Tuning = ShotTracker.Tuning(), netCheck useNet: Bool = true) -> TraceReplay {
        var out = TraceReplay()
        var tracker = ShotTracker(aspect: aspect, tuning: tuning)
        var smoother = HoopRectSmoother()
        var meter = NetMotionMeter()
        var check = NetCheck<Void>()

        func add(_ call: NetCheck<Void>.Call, at t: Double, responds: Bool?) {
            let arrival = call.outcome.rimArrivalTime ?? call.outcome.lastSeenTime
            let swing = responds == false ? nil : meter.swing(after: arrival)
            out.decisions.append(TraceDecision(call: ShotReplay.Call(time: arrival, result: call.result, confidence: call.confidence),
                                               outcome: call.outcome, swing: swing, publishedAt: t))
        }

        for entry in entries.sorted(by: { $0.timestampSec < $1.timestampSec }) {
            let t = entry.timestampSec
            if let rim = smoother.choose(from: entry.rimBox.flatMap(rect).map { [$0] } ?? []) {
                smoother.update(basketRect: rim, timestamp: t)
            } else {
                smoother.updateNoDetection(timestamp: t)
            }
            let hoop = smoother.state == .looking ? nil : smoother.smoothedRect
            if useNet, let activity = entry.netActivity {
                meter.record(activity, at: t)
            } else {
                meter.reset()
            }
            let balls = entry.balls?.compactMap { rect(Array($0.prefix(4))) }
                ?? entry.ballBox.flatMap(rect).map { [$0] } ?? []
            let locked = tracker.lockedHoop
            let event = tracker.update(balls: balls, hoop: hoop, time: t)
            out.frames.append(TraceFrame(time: t, hoop: hoop, tracking: tracker.isTrackingShot,
                                         shotBall: tracker.shotBallBox, locked: tracker.lockedHoop ?? locked, event: event))
            switch event {
            case .started:
                let r = check.netResponds
                if let call = check.flush(meter: meter) { add(call, at: t, responds: r) }
            case .resolved(let outcome):
                let r = check.netResponds
                for call in check.submit(outcome, context: (), now: t, meter: meter) { add(call, at: t, responds: r) }
            case nil:
                let r = check.netResponds
                if let call = check.due(now: t, meter: meter) { add(call, at: t, responds: r) }
            }
        }
        let r = check.netResponds
        if let call = check.flush(meter: meter) { add(call, at: entries.last?.timestampSec ?? 0, responds: r) }
        return out
    }

    private static func rect(_ values: [Double]) -> CGRect? {
        guard values.count >= 4, values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}

enum TraceReport {

    private static func f(_ v: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }

    /// NetMotionMeter.swing for `arrival` as the net check would have
    /// measured it 0.7 s later, replayed from the log (a frame without
    /// netActivity resets the meter, as in ShotReplay).
    static func swing(_ run: SimulationRun, arrival: Double) -> Double? {
        var meter = NetMotionMeter()
        let end = NetMotionMeter.decisionTime(arrival: arrival)
        for entry in run.entries where entry.timestampSec >= arrival - 4 && entry.timestampSec <= end {
            if let a = entry.netActivity { meter.record(a, at: entry.timestampSec) } else { meter.reset() }
        }
        return meter.swing(after: arrival)
    }

    /// For misses called makes: what the net said (the check only runs on
    /// calls under 0.9 confidence).
    static func netOnWrongMakes(_ run: SimulationRun, replay: TraceReplay) -> String? {
        let labels = run.labels
        let matched = Benchmark.pairs(calls: replay.calls, labels: labels)
        var total = 0, sure = 0, quietSure = 0, noFootage = 0
        for p in matched where replay.calls[p.call].result == .make && labels[p.label].result == .miss {
            total += 1
            let d = replay.decisions[p.call]
            guard !ShotEvidence.needsNetCheck(confidence: d.outcome.confidence) else { continue }
            sure += 1
            if let swing = swing(run, arrival: d.call.time) {
                if swing < ShotEvidence.strongSwing { quietSure += 1 }
            } else {
                noFootage += 1
            }
        }
        guard total > 0 else { return nil }
        return "misses called makes: \(total); \(sure) at confidence ≥ 0.9 skipped the net check, and for \(quietSure) of those "
            + "the net swing was below \(f(ShotEvidence.strongSwing, 1))" + (noFootage > 0 ? " (\(noFootage) without net footage)" : "")
    }

    /// Sessions where the replayed hoop (from the logged top basket only)
    /// sat on something other than the real hoop for over a third of the
    /// session.
    static func wrongHoop(_ run: SimulationRun, replay: TraceReplay) -> [String] {
        var out: [String] = []
        for (n, session) in run.sessions.enumerated() {
            guard let truth = session.camera.hoopBox(withNet: true)?.cgRect else { continue }
            var frames = 0, wrong = 0
            var firstWrong: Double?
            for fr in replay.frames where fr.time >= session.start && fr.time <= session.end {
                guard let hoop = fr.hoop else { continue }
                frames += 1
                if HoopRectSmoother.overlap(hoop, truth) < 0.2 {
                    wrong += 1
                    if firstWrong == nil { firstWrong = fr.time }
                }
            }
            if frames > 0, Double(wrong) / Double(frames) > 1.0 / 3 {
                out.append("session \(n + 1) (\(f(session.start, 1))–\(f(session.end, 1)) s): replayed hoop on the wrong basket "
                           + "\(Int(100 * Double(wrong) / Double(frames)))% of frames from \(f(firstWrong ?? 0)) s")
            }
        }
        return out
    }

    /// Explanations for every shot the tracker got wrong in `run`.
    static func failures(_ run: SimulationRun, replay: TraceReplay, limit: Int) -> [String] {
        let calls = replay.calls
        let labels = run.labels
        let matched = Benchmark.pairs(calls: calls, labels: labels)
        var out: [String] = []
        let labelToCall = Dictionary(uniqueKeysWithValues: matched.map { ($0.label, $0.call) })
        let pairedCalls = Set(matched.map(\.call))

        for (l, shot) in run.shots.enumerated() {
            if let c = labelToCall[l] {
                if calls[c].result != shot.result {
                    out.append(explain(run, replay: replay, shot: shot, decision: replay.decisions[c]))
                }
            } else {
                out.append(explain(run, replay: replay, shot: shot, decision: nil))
            }
        }
        for (c, decision) in replay.decisions.enumerated() where !pairedCalls.contains(c) {
            out.append(explainPhantom(run, replay: replay, decision: decision))
        }
        return Array(out.prefix(limit))
    }

    // MARK: Pieces

    private static func frameRange(_ run: SimulationRun, from t0: Double, to t1: Double) -> Range<Int> {
        let lo = run.frames.firstIndex { $0.time >= t0 } ?? run.frames.count
        let hi = run.frames.lastIndex { $0.time <= t1 }.map { $0 + 1 } ?? lo
        return lo..<max(lo, hi)
    }

    /// Detection runs for one ball: "34.10–34.25 hidden(head0) 9f".
    private static func detectorStory(_ run: SimulationRun, ball: Int, range: Range<Int>) -> String {
        var seen = 0, total = 0
        var gaps: [String] = []
        var current: (status: String, start: Double, end: Double, n: Int)?
        func close() {
            if let c = current { gaps.append("\(f(c.start))–\(f(c.end)) \(c.status) \(c.n)f") }
            current = nil
        }
        for k in range {
            guard let view = run.frames[k].views.first(where: { $0.id == ball }) else { continue }
            total += 1
            if view.status == .detected {
                seen += 1
                close()
                continue
            }
            var status = view.status.rawValue
            if view.status == .hidden, let by = view.hiddenBy { status += "(\(by))" }
            if let c = current, c.status == status {
                current = (status, c.start, run.frames[k].time, c.n + 1)
            } else {
                close()
                current = (status, run.frames[k].time, run.frames[k].time, 1)
            }
        }
        close()
        let gapText = gaps.isEmpty ? "" : "; gaps " + gaps.prefix(6).joined(separator: ", ") + (gaps.count > 6 ? ", …" : "")
        return "detector: ball\(ball) seen \(seen)/\(total) frames\(gapText)"
    }

    /// Which detection source the tracker's shot ball came from, frame by frame.
    private static func followed(_ run: SimulationRun, replay: TraceReplay, range: Range<Int>) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for k in range where k < replay.frames.count {
            guard let box = replay.frames[k].shotBall else { continue }
            let entry = run.entries[k]
            guard let balls = entry.balls,
                  let i = balls.firstIndex(where: { abs($0[0] - Double(box.minX)) < 1e-9 && abs($0[1] - Double(box.minY)) < 1e-9 }),
                  i < run.frames[k].sources.count else { continue }
            let name = run.frames[k].sources[i].description
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { "\($0) ×\(counts[$0] ?? 0)" }.joined(separator: ", ")
    }

    /// Where the followed object really was at frame `k`, relative to the rim
    /// as seen from the camera ("0.31 m in front of the rim centre").
    private static func whereReally(_ run: SimulationRun, replay: TraceReplay, frame k: Int) -> String? {
        guard let box = replay.frames[k].shotBall, let balls = run.entries[k].balls,
              let i = balls.firstIndex(where: { abs($0[0] - Double(box.minX)) < 1e-9 && abs($0[1] - Double(box.minY)) < 1e-9 }),
              i < run.frames[k].sources.count else { return nil }
        guard case .ball(let id) = run.frames[k].sources[i] else { return "really \(run.frames[k].sources[i])" }
        guard let view = run.frames[k].views.first(where: { $0.id == id }),
              let session = run.sessions.last(where: { $0.start <= run.frames[k].time }) else { return nil }
        let forward = session.camera.forward.horizontal.normalized
        let right = session.camera.right.horizontal.normalized
        let rel = view.world - Court.rimCentre
        let along = rel.horizontal.dot(forward), side = rel.dot(right)
        let radial = rel.horizontal.length
        var place = radial < Court.rimInnerRadius ? "inside the ring's circle"
            : along < 0 ? "\(f(-along)) m in front of the rim centre" : "\(f(along)) m behind the rim centre"
        place += ", \(f(abs(side))) m \(side < 0 ? "left" : "right"), \(f(view.world.y)) m up"
        if view.inNet { place += ", in the net" }
        return "really ball\(id) " + place
    }

    /// The tracker's ball relative to the locked rim: drops through the rim
    /// line (with column offset) and pops back above it.
    private static func rimStory(_ run: SimulationRun, replay: TraceReplay, range: Range<Int>,
                                 aspect: Double = 16.0 / 9.0) -> [String] {
        var lines: [String] = []
        var previous: (t: Double, x: Double, y: Double)?
        var above = false
        for k in range where k < replay.frames.count {
            let fr = replay.frames[k]
            guard let ball = fr.shotBall, let hoop = fr.locked else { previous = nil; continue }
            let x = Double(ball.midX), y = Double(ball.midY)
            let rimLine = Double(hoop.maxY) - 0.15 * Double(hoop.height)
            let rimUnit = Double(hoop.width) * aspect
            let truth = whereReally(run, replay: replay, frame: k).map { " — " + $0 } ?? ""
            if let p = previous, p.y > rimLine, y <= rimLine {
                let s = (p.y - rimLine) / max(p.y - y, 1e-9)
                let crossX = p.x + (x - p.x) * s
                let offset = abs(crossX - Double(hoop.midX)) / Double(hoop.width)
                lines.append("down through rim line at \(f(p.t + (fr.time - p.t) * s)) offset \(f(offset)) (column ≤ 0.55)" + truth)
            }
            if y > rimLine + 0.35 * rimUnit {
                if !above, previous.map({ $0.y <= rimLine + 0.35 * rimUnit }) == true {
                    lines.append("back above rim line +0.35 at \(f(fr.time))" + truth)
                }
                above = true
            } else {
                above = false
            }
            if y < Double(hoop.minY), let p = previous, p.y >= Double(hoop.minY) {
                let offset = abs(x - Double(hoop.midX)) / Double(hoop.width)
                lines.append("below the net box at \(f(fr.time)) offset \(f(offset))" + truth)
            }
            previous = (fr.time, x, y)
        }
        return lines
    }

    private static func how(_ o: ShotTracker.Outcome) -> String {
        let explanation = explain(o)
        return o.doubts.contains(.secondBall) ? explanation + "; another ball right next to it at the rim" : explanation
    }

    private static func explain(_ o: ShotTracker.Outcome) -> String {
        var doubts: [String] = []
        if o.doubts.contains(.tooBigForRim) { doubts.append("too big for the rim's depth") }
        if o.doubts.contains(.cameBack) { doubts.append("came back off the rim or board") }
        if !doubts.isEmpty { return "out of the net in 2D, doubted: " + doubts.joined(separator: ", ") }
        switch (o.result, o.confidence) {
        case (.make, 0.95): return "left the bottom of the net in the column"
        case (.make, 0.8): return "sat 0.45 s at the rim, still seen"
        case (.make, 0.7): return "sat 0.45 s at the rim, not seen"
        case (.miss, 0.9): return "dropped past rim height well outside it"
        case (.miss, 0.65): return "dropped past rim height just outside the column (grazed)"
        case (.miss, 0.8): return "kicked out sideways from the rim"
        case (_, 0.35): return "ball lost for 0.9 s; guessed"
        case (_, 0.3): return "3.5 s flight timeout; guessed"
        default: return "conf \(f(o.confidence))"
        }
    }

    private static func trackerStory(_ replay: TraceReplay, range: Range<Int>) -> [String] {
        var lines: [String] = []
        for k in range where k < replay.frames.count {
            switch replay.frames[k].event {
            case .started(let r)?:
                lines.append("start at \(f(replay.frames[k].time)), release taken at \(f(r.time))")
            case .resolved(let o)?:
                let arrival = o.rimArrivalTime.map { f($0) } ?? "–"
                lines.append("\(o.result == .make ? "MAKE" : "MISS") \(f(o.confidence)) at \(f(replay.frames[k].time)) (arrival \(arrival)): \(how(o))")
            case nil:
                break
            }
        }
        return lines
    }

    private static func netStory(_ d: TraceDecision) -> String {
        let tracker = "\(d.outcome.result == .make ? "make" : "miss") \(f(d.outcome.confidence))"
        let published = "\(d.call.result == .make ? "make" : "miss") \(f(d.call.confidence))"
        if !ShotEvidence.needsNetCheck(confidence: d.outcome.confidence) {
            return "net check: not needed (tracker sure: \(tracker))"
        }
        let swing = d.swing.map { f($0, 1) } ?? "n/a"
        return "net check: swing \(swing) (make ≥ \(f(ShotEvidence.strongSwing, 1)), still ≤ \(f(ShotEvidence.quietSwing, 1))): \(tracker) → \(published)"
    }

    private static func truthLine(_ shot: ShotTruth) -> String {
        let m = shot.monitor
        let rims = m.contacts.filter { $0.kind == .rim && $0.time <= (m.madeTime ?? m.finishedAt ?? .infinity) }
        let boards = m.contacts.filter { $0.kind == .board && $0.time <= (m.madeTime ?? m.finishedAt ?? .infinity) }
        var bits: [String] = []
        if let first = rims.first {
            let s = (first.point - Court.rimCentre).horizontal.dot(m.direction)
            bits.append("rim×\(rims.count) (first \(s > 0.12 ? "back" : s < -0.12 ? "front" : "side") at \(f(first.time)))")
        }
        if let b = boards.first { bits.append("board×\(boards.count) at \(f(b.time))") }
        if let made = m.madeTime { bits.append("in net \(f(made))") }
        let entry = m.entryAngle.map { "\(Int($0.rounded()))°" } ?? "–"
        return "truth: \(shot.result == .make ? "MAKE" : "MISS") \(shot.kind.rawValue) by shooter \(shot.shooter), "
            + "\(f(shot.distance, 1)) m, release \(f(shot.releaseTime)) at \(f(shot.releasePoint.y)) m, label \(f(shot.labelTime)), "
            + "entry \(entry)" + (bits.isEmpty ? "" : "; " + bits.joined(separator: ", "))
    }

    /// Why no shot started: the true ball's detections from the tracker's
    /// point of view — dropped as too big (maxBallToRim), then the best
    /// rising run judged like tryStart.
    private static func startStory(_ run: SimulationRun, replay: TraceReplay, shot: ShotTruth, range: Range<Int>) -> String {
        let tuning = ShotTracker.Tuning()
        var samples: [(t: Double, y: Double)] = []
        var tooBig = 0, usable = 0, maxRatio = 0.0
        var lastTooBig: Double?
        var best: (rise: Double, speed: Double, count: Int, height: Double)?
        var bestScore = -Double.infinity
        for k in range where k < run.entries.count {
            let fr = run.frames[k]
            guard fr.time <= shot.labelTime, let i = fr.sources.firstIndex(of: .ball(shot.ball)),
                  let box = run.entries[k].balls?[i], let hoop = replay.frames[k].hoop else { continue }
            let ratio = box[2] / Double(hoop.width)
            if fr.time >= shot.releaseTime - 0.1 { maxRatio = max(maxRatio, ratio) }
            if ratio > tuning.maxBallToRim {
                tooBig += 1
                lastTooBig = fr.time
                continue
            }
            usable += 1
            let y = box[1] + box[3] / 2
            let rimUnit = Double(hoop.width) * 16 / 9
            let rimLine = Double(hoop.maxY) - 0.15 * Double(hoop.height)
            if let last = samples.last, y < last.y - 0.05 * rimUnit || fr.time - last.t > 0.25 { samples = [] }
            samples.append((fr.time, y))
            if samples.count >= 4 {
                let rise = (y - samples[0].y) / rimUnit
                let j = max(0, samples.count - 3)
                let speed = (y - samples[j].y) / max(fr.time - samples[j].t, 1e-9) / rimUnit
                let height = (y - rimLine) / rimUnit
                // Closest to passing all three tests.
                let score = min(rise / tuning.minRise, speed / tuning.minRiseSpeed, (height + tuning.startBelowRimTolerance + 1))
                if score > bestScore { bestScore = score; best = (rise, speed, samples.count, height) }
            }
        }
        var text = "no start: "
        if tooBig > 0 {
            text += "\(tooBig) detections dropped as too big (ball/rim width up to \(f(maxRatio, 1)) > \(f(tuning.maxBallToRim, 1))"
                + (lastTooBig.map { ", until \(f($0))" } ?? "") + "); "
        }
        guard let best else { return text + "\(usable) usable detections, never 4 in a rising run" }
        return text + "best rising run \(best.count) detections: rise \(f(best.rise, 1)) rim (need \(f(tuning.minRise, 1))), "
            + "speed \(f(best.speed, 1)) rim/s (need \(f(tuning.minRiseSpeed, 1))), "
            + "height \(f(best.height, 1)) rim vs rim line (need ≥ \(f(-tuning.startBelowRimTolerance, 2)))"
    }

    static func explain(_ run: SimulationRun, replay: TraceReplay, shot: ShotTruth, decision: TraceDecision?) -> String {
        let truth = shot.result == .make ? "MAKE" : "MISS"
        let title: String
        if let d = decision {
            title = "✗ shot #\(shot.index + 1): \(truth) called \(d.call.result == .make ? "MAKE" : "MISS") \(f(d.call.confidence))"
                + (d.call.confidence < HoopTrack.CV.lowConfidence ? " (flagged)" : "")
        } else {
            title = "✗ shot #\(shot.index + 1): \(truth) never called"
        }
        let range = frameRange(run, from: shot.releaseTime - 0.6, to: shot.labelTime + 1.6)
        var lines = [title, "  " + truthLine(shot)]
        if let session = run.sessions.first(where: { $0.start <= shot.releaseTime && $0.end >= shot.releaseTime }) {
            let cam = session.camera.position
            lines.append("  camera: \(f((cam - shot.releasePoint).horizontal.length, 1)) m from the release, "
                         + "\(f((cam - Court.rimCentre).horizontal.length, 1)) m from the rim, \(f(cam.y)) m up")
        }
        lines.append("  " + detectorStory(run, ball: shot.ball, range: frameRange(run, from: shot.releaseTime - 0.3, to: shot.labelTime + 0.8)))
        let follow = followed(run, replay: replay, range: range)
        lines.append("  tracker followed: " + (follow.isEmpty ? "nothing" : follow))
        let events = trackerStory(replay, range: range)
        lines += events.map { "  tracker: " + $0 }
        lines += rimStory(run, replay: replay, range: range).map { "  rim: " + $0 }
        if let d = decision {
            lines.append("  " + netStory(d))
        } else if !events.contains(where: { $0.hasPrefix("start") }) {
            let busy = range.contains { k in k < replay.frames.count && replay.frames[k].tracking && replay.frames[k].time < shot.releaseTime + 0.2 }
            lines.append("  " + (busy ? "tracker was busy with another shot at release; " : "") + startStory(run, replay: replay, shot: shot, range: range))
        }
        return lines.joined(separator: "\n")
    }

    static func explainPhantom(_ run: SimulationRun, replay: TraceReplay, decision: TraceDecision) -> String {
        let d = decision
        let range = frameRange(run, from: d.outcome.release.time - 0.4, to: d.publishedAt + 0.1)
        var lines = ["✗ phantom \(d.call.result == .make ? "MAKE" : "MISS") \(f(d.call.confidence)) at \(f(d.call.time)) (no shot within 1.5 s)"]
        let follow = followed(run, replay: replay, range: range)
        lines.append("  tracker followed: " + (follow.isEmpty ? "nothing logged" : follow))
        // What the followed ball really was doing.
        if let k = range.first(where: { $0 < replay.frames.count && replay.frames[$0].shotBall != nil }),
           let box = replay.frames[k].shotBall, let balls = run.entries[k].balls,
           let i = balls.firstIndex(where: { abs($0[0] - Double(box.minX)) < 1e-9 }), i < run.frames[k].sources.count,
           case .ball(let id) = run.frames[k].sources[i] {
            let nearShot = run.shots.first { $0.ball == id && abs($0.releaseTime - d.outcome.release.time) < 3 }
            let isShot = nearShot.map { abs($0.releaseTime - d.outcome.release.time) < 0.4 } ?? false
            lines.append("  ball\(id) at start: " + (isShot ? "shot #\(nearShot!.index + 1) (\(nearShot!.kind.rawValue), label \(f(nearShot!.labelTime)))"
                                                     : "not a shot"))
        }
        let start = d.outcome.release.time
        let doing = run.actions.filter { $0.time >= start - 2.0 && $0.time <= start + 0.3 }
        if !doing.isEmpty {
            lines.append("  people: " + doing.map { "\(f($0.time)) person\($0.person) \($0.what)" }.joined(separator: "; "))
        }
        lines += trackerStory(replay, range: range).map { "  tracker: " + $0 }
        lines += rimStory(run, replay: replay, range: range).map { "  rim: " + $0 }
        lines.append("  " + netStory(d))
        return lines.joined(separator: "\n")
    }
}
