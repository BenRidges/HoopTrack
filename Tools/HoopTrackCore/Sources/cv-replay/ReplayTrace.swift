// ReplayTrace.swift
// ShotReplay.run (what shot-eval does), step for step, but keeping what
// cv-replay needs to line its calls up with the live delegate's and to
// draw the shot strips: the frame each call was published on, the
// tracker's full outcome (release time, rim arrival), the smoothed hoop
// and the tracked shot ball on every frame.
//
// It must agree exactly with ShotReplay.run; cv-replay checks that on
// every run and says so if it doesn't (that would be a bug here, not in
// the app).

import CoreGraphics
import Foundation
@testable import HoopTrack

enum ReplayTrace {

    struct Frame {
        let t: Double
        /// Smoothed hoop the tracker saw (nil while looking).
        let hoop: CGRect?
        /// 0 looking, 1 tracking, 2 lost.
        let hoopKind: Int
        /// The tracker's shot ball after this frame (nil between shots).
        let shotBall: CGRect?
        let event: ShotTracker.Event?
    }

    struct Call {
        /// As ShotReplay.Call: rim arrival, else when the ball was last seen.
        let time: Double
        let result: ShotResult
        let confidence: Double
        /// Log time of the frame it was published on; nil for the final
        /// flush after the last frame.
        let publishedAt: Double?
        let publishedEntry: Int?
        let outcome: ShotTracker.Outcome

        var replayCall: ShotReplay.Call { ShotReplay.Call(time: time, result: result, confidence: confidence) }
    }

    static func run(_ entries: [DetectionLogEntry],
                    aspect: Double = 16.0 / 9.0,
                    tuning: ShotTracker.Tuning = ShotTracker.Tuning(),
                    netCheck useNet: Bool = true) -> (calls: [Call], frames: [Frame]) {
        var tracker = ShotTracker(aspect: aspect, tuning: tuning)
        var smoother = HoopRectSmoother()
        var meter = NetMotionMeter()
        var check = NetCheck<Void>()
        var calls: [Call] = []
        var frames: [Frame] = []

        func add(_ call: NetCheck<Void>.Call, at index: Int?, t: Double?) {
            calls.append(Call(time: call.outcome.rimArrivalTime ?? call.outcome.lastSeenTime,
                              result: call.result, confidence: call.confidence,
                              publishedAt: t, publishedEntry: index, outcome: call.outcome))
        }

        let sorted = entries.sorted(by: { $0.timestampSec < $1.timestampSec })
        for (index, entry) in sorted.enumerated() {
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
            let event = tracker.update(balls: balls, hoop: hoop, time: t)
            switch event {
            case .started:
                if let call = check.flush(meter: meter) { add(call, at: index, t: t) }
            case .resolved(let outcome):
                check.submit(outcome, context: (), now: t, meter: meter).forEach { add($0, at: index, t: t) }
            case nil:
                if let call = check.due(now: t, meter: meter) { add(call, at: index, t: t) }
            }
            let kind: Int
            switch smoother.state {
            case .looking:  kind = 0
            case .tracking: kind = 1
            case .lost:     kind = 2
            }
            frames.append(Frame(t: t, hoop: hoop, hoopKind: kind, shotBall: tracker.shotBallBox, event: event))
        }
        if let call = check.flush(meter: meter) { add(call, at: nil, t: nil) }
        return (calls, frames)
    }

    private static func rect(_ values: [Double]) -> CGRect? {
        guard values.count >= 4, values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}
