// AppPipeline.swift
// What CVPipeline.process does with each frame, minus AVFoundation: the
// hoop smoother (CourtCalibrationService), the tracker, NetWatch and
// NetCheck, in the same order, writing the same DetectionLogEntry.
//
// The simulator needs it because detection depends on the tracker's state:
// while a shot is in flight the app detects in a crop around the hoop and
// the ball (DetectionRegion), and NetWatch aims at the hoop the tracker has
// locked. Running the app's own types in the loop keeps the generated log
// faithful to what a phone would have written.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import HoopTrack

extension Box {
    var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
    init(_ r: CGRect) { self.init(minX: Double(r.minX), minY: Double(r.minY), width: Double(r.width), height: Double(r.height)) }
}

struct AppPipeline {
    private(set) var tracker: ShotTracker
    private var smoother = HoopRectSmoother()
    private var net = NetWatch()
    private var check = NetCheck<Void>()
    let frameWidth: Double
    let frameHeight: Double
    /// Calls as the app would have published them (after the net check).
    private(set) var published: [ShotReplay.Call] = []

    init(aspect: Double = 16.0 / 9.0, frameWidth: Double = 1280, frameHeight: Double = 720) {
        tracker = ShotTracker(aspect: aspect)
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }

    /// The hoop as CourtCalibrationService reports it (last-known while lost).
    var calibratedHoop: CGRect? { smoother.state == .looking ? nil : smoother.smoothedRect }

    /// CVPipeline.focusRegion: a crop while a shot is in flight.
    func region() -> CGRect? {
        guard HoopTrack.CV.focusDuringShots, let ball = tracker.shotBallBox, let hoop = calibratedHoop else { return nil }
        return DetectionRegion.around(hoop: hoop, ball: ball, frameWidth: frameWidth, frameHeight: frameHeight)
    }

    /// The hoop NetWatch should sample under this frame.
    var netHoop: CGRect? { tracker.lockedHoop ?? check.heldHoop ?? calibratedHoop }

    /// One processed frame. `luma` renders brightness at NetWatch's grid
    /// points (nil = couldn't read the frame).
    mutating func process(time: Double, scene: SceneDetections, region: CGRect?,
                          luma: ([CGPoint]) -> [UInt8]?) -> DetectionLogEntry {
        // CourtCalibrationService.updateBaskets
        if let rim = smoother.choose(from: scene.baskets.map { $0.box.cgRect }) {
            smoother.update(basketRect: rim, timestamp: time)
        } else {
            smoother.updateNoDetection(timestamp: time)
        }

        // watchNet (before the tracker, as in the app)
        let points = net.aim(at: netHoop, aspect: tracker.aspect)
        let activity = net.observe(points.isEmpty ? nil : luma(points), at: time)

        let event = tracker.update(balls: scene.balls.map { $0.box.cgRect }, hoop: calibratedHoop, time: time)
        var calls: [NetCheck<Void>.Call] = []
        switch event {
        case .started:
            if let call = check.flush(meter: net.meter) { calls.append(call) }
        case .resolved(let outcome):
            calls += check.submit(outcome, context: (), now: time, meter: net.meter)
        case nil:
            if let call = check.due(now: time, meter: net.meter) { calls.append(call) }
        }
        for call in calls {
            published.append(ShotReplay.Call(time: call.outcome.rimArrivalTime ?? call.outcome.lastSeenTime,
                                             result: call.result, confidence: call.confidence))
        }

        // logTelemetry
        let top = scene.balls.first, basket = scene.baskets.first
        var entry = DetectionLogEntry(timestampSec: time,
                                      ballConfidence: top.map(\.confidence),
                                      ballBox: top.map(\.box.array),
                                      rimConfidence: basket.map(\.confidence),
                                      rimBox: basket.map(\.box.array),
                                      state: tracker.isTrackingShot ? "tracking" : "idle")
        entry.balls = scene.balls.map { $0.box.array + [$0.confidence] }
        entry.region = region.map { Box($0).array }
        switch event {
        case .started:
            entry.event = "start"
        case .resolved(let outcome):
            entry.event = outcome.result == .make ? "make" : "miss"
            entry.eventConfidence = outcome.confidence
        case nil:
            break
        }
        entry.netActivity = activity
        if let last = calls.last {
            entry.checkedEvent = last.result == .make ? "make" : "miss"
            entry.checkedConfidence = last.confidence
        }
        return entry
    }

    /// A frame with nothing usable (the phone being moved).
    mutating func blank(time: Double) -> DetectionLogEntry {
        process(time: time, scene: SceneDetections(balls: [], baskets: [], views: []), region: nil, luma: { _ in nil })
    }

    /// End of the recording: anything still held is published as is.
    mutating func finish() {
        if let call = check.flush(meter: net.meter) {
            published.append(ShotReplay.Call(time: call.outcome.rimArrivalTime ?? call.outcome.lastSeenTime,
                                             result: call.result, confidence: call.confidence))
        }
    }
}
