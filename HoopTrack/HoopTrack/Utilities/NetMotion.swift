// NetMotion.swift
// A second opinion on make / miss from the net itself (CV-D).
//
// When a shot goes in, the net keeps swinging for half a second or more
// after the ball has dropped out of it. A ball that only passes in front
// of or behind the net makes a short flicker. So: sample brightness on a
// small grid where the net hangs, measure frame-to-frame change, and
// compare the stretch just after the ball reached the rim with the quiet
// before the shot.
//
// The tracker's geometry is still the main signal. Net motion only firms
// up or flags calls the tracker wasn't sure of (ShotEvidence.fuse), and it
// can rescue a ball the tracker lost behind the rim.
//
// Pure logic; CVPipeline does the pixel reads.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated enum NetMotion {

    /// Where the net hangs, Vision-normalised: from the rim line down about
    /// one rim diameter, slightly narrower than the rim so the rim's own
    /// edges (which flicker in the detector's box) stay out of it.
    static func region(hoop: CGRect, aspect: Double) -> CGRect {
        let rimLine = Double(hoop.maxY) - 0.15 * Double(hoop.height)
        let depth = 1.1 * Double(hoop.width) * aspect
        let inset = 0.12 * Double(hoop.width)
        return CGRect(x: Double(hoop.minX) + inset, y: rimLine - depth,
                      width: max(0, Double(hoop.width) - 2 * inset), height: depth)
    }

    /// A grid of points inside `region`, cell centres, row by row.
    static func samplePoints(in region: CGRect, columns: Int = 12, rows: Int = 10) -> [CGPoint] {
        guard columns > 0, rows > 0, region.width > 0, region.height > 0 else { return [] }
        var points: [CGPoint] = []
        points.reserveCapacity(columns * rows)
        for r in 0..<rows {
            for c in 0..<columns {
                points.append(CGPoint(x: Double(region.minX) + (Double(c) + 0.5) / Double(columns) * Double(region.width),
                                      y: Double(region.minY) + (Double(r) + 0.5) / Double(rows) * Double(region.height)))
            }
        }
        return points
    }

    /// Mean absolute brightness change between two samplings, 0–1.
    static func activity(previous: [UInt8], current: [UInt8]) -> Double? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var total = 0
        for i in current.indices { total += abs(Int(current[i]) - Int(previous[i])) }
        return Double(total) / Double(current.count) / 255
    }
}

/// Rolling record of net activity for the last few seconds.
nonisolated struct NetMotionMeter: Sendable {

    private var samples: [(time: Double, activity: Double)] = []
    private let keep: Double

    init(keepSeconds: Double = 4) {
        keep = keepSeconds
    }

    mutating func record(_ activity: Double, at time: Double) {
        samples.append((time, activity))
        samples.removeAll { time - $0.time > keep }
    }

    mutating func reset() {
        samples.removeAll()
    }

    /// The latest time `swing(after:)` needs footage up to.
    static func decisionTime(arrival: Double) -> Double { arrival + 0.7 }

    /// How hard the net was moving just after the ball reached the rim,
    /// relative to before the shot (1 = no change). Nil when there's too
    /// little footage either side.
    func swing(after arrival: Double) -> Double? {
        let before = samples.filter { $0.time >= arrival - 1.5 && $0.time <= arrival - 0.25 }.map(\.activity)
        // Starts 0.2 s after arrival so the ball itself has mostly cleared
        // the net region; what's left is the net moving.
        let after = samples.filter { $0.time >= arrival + 0.2 && $0.time <= arrival + 0.7 }.map(\.activity)
        guard before.count >= 5, after.count >= 5 else { return nil }
        let baseline = max(Self.median(before), 0.004)
        let swinging = after.reduce(0, +) / Double(after.count)
        return swinging / baseline
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// Combines the tracker's call with other evidence into the shot that's logged.
nonisolated enum ShotEvidence {

    /// Net swing at or above this is a clear "the net moved" (a make).
    static let strongSwing = 3.0
    /// At or below this the net barely moved.
    static let quietSwing = 1.3

    /// - Parameters:
    ///   - result/confidence: the tracker's call.
    ///   - netSwing: `NetMotionMeter.swing`, nil when unavailable.
    ///   - doubts: what argued against the tracker's call (`Outcome.doubts`).
    ///   - netResponds: whether this net swings on clean makes
    ///     (`NetCheck.netResponds`), nil until known.
    /// - Returns: the call to log. Confidence below `HoopTrack.CV.lowConfidence`
    ///   gets the shot flagged for review.
    static func fuse(result: ShotResult, confidence: Double, netSwing: Double?,
                     doubts: ShotTracker.Doubts = [], netResponds: Bool? = nil) -> (result: ShotResult, confidence: Double) {
        guard let swing = netSwing else { return (result, confidence) }
        switch result {
        case .make:
            // A make the tracker saw leave the bottom of the net (0.95) stands.
            // With a second ball at the rim the net can't say which one
            // went in, so it doesn't clear the flag.
            if swing >= strongSwing {
                return (.make, doubts.contains(.secondBall) ? confidence : max(confidence, 0.9))
            }
            if swing <= quietSwing && confidence < 0.9 {
                // Its size put the ball off the rim's depth, and a net known
                // to swing on clean makes stayed still: it dropped in front
                // of (or beyond) the rim. Flagged all the same. Real nets
                // that swing (2026-11 Somorin clips, from the tracker's
                // arrival) measured ≥ 2.0 after every make and ≤ 1.3 after
                // every miss, rim hits included.
                if !doubts.isDisjoint(with: .depth) && netResponds == true { return (.miss, 0.5) }
                return (.make, min(confidence, 0.5))
            }
        case .miss:
            // Ball lost near the rim and the net jumped: probably went in.
            if confidence <= 0.4 && swing >= strongSwing { return (.make, 0.55) }
            // Grazed the rim and the net moved a lot: worth a second look.
            if confidence < 0.9 && swing >= strongSwing + 1 { return (.miss, min(confidence, 0.5)) }
        case .pending:
            break
        }
        return (result, confidence)
    }

    /// Calls this sure don't wait for the net.
    static func needsNetCheck(confidence: Double) -> Bool { confidence < 0.9 }
}

/// Keeps the sampling grid on the net and feeds each frame's brightness
/// samples into a NetMotionMeter. The grid only moves when the hoop really
/// has (more than a tenth of a rim): re-aiming on every wobble of the
/// detected box would itself look like the net moving.
///
/// Any frame without samples (no hoop, grid just moved) clears the meter,
/// so a swing is only ever measured over one steady view of the net. The
/// replay tool relies on this: a log line without `netActivity` = a reset.
nonisolated struct NetWatch: Sendable {

    private(set) var points: [CGPoint] = []
    private(set) var meter = NetMotionMeter()
    private var anchor: CGRect?
    private var previous: [UInt8]?

    /// The points to sample this frame (Vision-normalised); empty with no hoop.
    mutating func aim(at hoop: CGRect?, aspect: Double) -> [CGPoint] {
        guard let hoop, hoop.width > 0, hoop.height > 0 else {
            anchor = nil
            points = []
            previous = nil
            return []
        }
        if let anchor, !Self.hasMoved(from: anchor, to: hoop, aspect: aspect) { return points }
        anchor = hoop
        points = NetMotion.samplePoints(in: NetMotion.region(hoop: hoop, aspect: aspect))
        previous = nil
        return points
    }

    /// This frame's brightness at `points`, nil if it couldn't be read.
    /// Returns the activity recorded, if any.
    @discardableResult
    mutating func observe(_ luma: [UInt8]?, at time: Double) -> Double? {
        defer { previous = luma }
        guard let luma, let previous,
              let activity = NetMotion.activity(previous: previous, current: luma) else {
            meter.reset()
            return nil
        }
        meter.record(activity, at: time)
        return activity
    }

    mutating func reset() {
        anchor = nil
        points = []
        previous = nil
        meter.reset()
    }

    static func hasMoved(from a: CGRect, to b: CGRect, aspect: Double) -> Bool {
        let tolerance = 0.1 * Double(a.width)
        return abs(Double(a.midX - b.midX)) > tolerance
            || abs(Double(a.midY - b.midY)) > tolerance * aspect
            || abs(Double(a.width - b.width)) > tolerance
    }
}

/// Holds a tracker call that wasn't sure until the net has had time to
/// swing, then settles it with ShotEvidence.fuse. Sure calls pass straight
/// through, so most shots still show the moment they resolve; the rest wait
/// at most ~0.7 s after the ball reached the rim.
///
/// `Context` rides along with the call (the app keeps the shot's court
/// position estimate there).
nonisolated struct NetCheck<Context: Sendable>: Sendable {

    struct Call: Sendable {
        let outcome: ShotTracker.Outcome
        let context: Context
        /// After the net check; the outcome keeps the tracker's own call.
        let result: ShotResult
        let confidence: Double
    }

    private var held: (outcome: ShotTracker.Outcome, context: Context, arrival: Double)?

    /// Arrival times of makes the tracker was sure of, waiting for footage,
    /// and the swings measured after them. A bare outdoor rim, a chain net
    /// or a net out of shot never swings, and then a still net proves nothing.
    private var sureMakes: [Double] = []
    private var sureMakeSwings: [Double] = []
    /// The rim those swings were measured under. What a net does is a
    /// property of that net seen from there: when the hoop turns up
    /// somewhere else in the picture (the phone was moved), it's unknown
    /// again.
    private var learnedHoop: CGRect?

    /// The rim of the call being held, so the net grid stays where the shot was.
    var heldHoop: CGRect? { held?.outcome.hoop }

    /// Whether the net visibly moves on clean makes; nil until two have been seen.
    var netResponds: Bool? {
        guard sureMakeSwings.count >= 2 else { return nil }
        let sorted = sureMakeSwings.sorted()
        return sorted[sorted.count / 2] >= ShotEvidence.strongSwing
    }

    /// A new call from the tracker. Returns what can be published now, in
    /// order: anything already held, then this call unless it's held.
    mutating func submit(_ outcome: ShotTracker.Outcome, context: Context,
                         now: Double, meter: NetMotionMeter) -> [Call] {
        var ready: [Call] = []
        if let earlier = flush(meter: meter) { ready.append(earlier) }
        if let learned = learnedHoop, Self.isAnotherView(learned, outcome.hoop) {
            sureMakes.removeAll()
            sureMakeSwings.removeAll()
        }
        learnedHoop = outcome.hoop
        guard ShotEvidence.needsNetCheck(confidence: outcome.confidence) else {
            if outcome.result == .make, let arrival = outcome.rimArrivalTime { sureMakes.append(arrival) }
            ready.append(Call(outcome: outcome, context: context,
                              result: outcome.result, confidence: outcome.confidence))
            return ready
        }
        // A lost ball was last seen near the rim, so that's when it got there.
        held = (outcome, context, outcome.rimArrivalTime ?? outcome.lastSeenTime)
        if let settled = due(now: now, meter: meter) { ready.append(settled) }
        return ready
    }

    /// The held call once the net has had its time. Call every frame.
    mutating func due(now: Double, meter: NetMotionMeter) -> Call? {
        learn(now: now, meter: meter)
        guard let held, now >= NetMotionMeter.decisionTime(arrival: held.arrival) else { return nil }
        return flush(meter: meter)
    }

    /// The held call, settled with whatever footage there is.
    mutating func flush(meter: NetMotionMeter) -> Call? {
        guard let held else { return nil }
        self.held = nil
        // On a net that doesn't move for clean makes, ignore it entirely.
        let responds = netResponds
        let swing = responds == false ? nil : meter.swing(after: held.arrival)
        let fused = ShotEvidence.fuse(result: held.outcome.result,
                                      confidence: held.outcome.confidence,
                                      netSwing: swing,
                                      doubts: held.outcome.doubts,
                                      netResponds: responds)
        return Call(outcome: held.outcome, context: held.context,
                    result: fused.result, confidence: fused.confidence)
    }

    mutating func drop() {
        held = nil
        sureMakes.removeAll()
    }

    /// The hoop moved by more than its own size, or changed size by a
    /// third: the camera was moved, not the box wobbling.
    static func isAnotherView(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(Double(a.midX - b.midX)) > Double(a.width)
            || abs(Double(a.midY - b.midY)) > Double(a.height)
            || abs(Double(b.width - a.width)) > Double(a.width) / 3
    }

    private mutating func learn(now: Double, meter: NetMotionMeter) {
        while let arrival = sureMakes.first, now >= NetMotionMeter.decisionTime(arrival: arrival) {
            sureMakes.removeFirst()
            if let swing = meter.swing(after: arrival) {
                sureMakeSwings.append(swing)
                if sureMakeSwings.count > 9 { sureMakeSwings.removeFirst() }
            }
        }
    }
}
