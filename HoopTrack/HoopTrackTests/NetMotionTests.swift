// HoopTrackTests/NetMotionTests.swift

import XCTest
@testable import HoopTrack
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class NetMotionTests: XCTestCase {

    private let hoop = CGRect(x: 0.45, y: 0.70, width: 0.10, height: 0.10)

    func test_region_hangsBelowTheRimLine_insideTheRim() {
        let region = NetMotion.region(hoop: hoop, aspect: 16.0 / 9.0)
        XCTAssertEqual(Double(region.maxY), 0.785, accuracy: 1e-9)       // rim line
        XCTAssertGreaterThan(Double(region.minX), Double(hoop.minX))
        XCTAssertLessThan(Double(region.maxX), Double(hoop.maxX))
        XCTAssertEqual(Double(region.height), 1.1 * 0.1 * 16 / 9, accuracy: 1e-9)
    }

    func test_samplePoints_fillTheRegion() {
        let region = CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.2)
        let points = NetMotion.samplePoints(in: region, columns: 4, rows: 5)
        XCTAssertEqual(points.count, 20)
        XCTAssertTrue(points.allSatisfy {
            $0.x > region.minX && $0.x < region.maxX && $0.y > region.minY && $0.y < region.maxY
        })
    }

    func test_activity_isMeanAbsoluteChange() {
        XCTAssertEqual(NetMotion.activity(previous: [10, 20, 30, 40], current: [10, 30, 10, 40])!,
                       Double(0 + 10 + 20 + 0) / 4 / 255, accuracy: 1e-12)
        XCTAssertNil(NetMotion.activity(previous: [1, 2], current: [1, 2, 3]))
    }

    /// Activity trace: quiet at `base`, then `after` from arrival+0.15 for `length` seconds.
    private func meter(base: Double, after: Double, length: Double, arrival: Double = 2.0) -> NetMotionMeter {
        var meter = NetMotionMeter()
        var t = 0.0
        while t <= arrival + 1.0 {
            let swinging = t >= arrival + 0.15 && t <= arrival + 0.15 + length
            meter.record(swinging ? after : base, at: t)
            t += 1.0 / 30
        }
        return meter
    }

    func test_swing_netKeepsMovingAfterAMake() {
        let swing = meter(base: 0.01, after: 0.06, length: 0.6).swing(after: 2.0)
        XCTAssertGreaterThan(swing!, ShotEvidence.strongSwing)
    }

    func test_swing_briefFlickerOfAPassingBall_isQuiet() {
        // Ball crosses the region for ~0.1 s right at arrival, then nothing.
        var meter = NetMotionMeter()
        var t = 0.0
        while t <= 3.0 {
            meter.record(t >= 2.0 && t <= 2.1 ? 0.08 : 0.01, at: t)
            t += 1.0 / 30
        }
        XCTAssertLessThanOrEqual(meter.swing(after: 2.0)!, ShotEvidence.quietSwing)
    }

    func test_swing_needsFootageBothSides() {
        var meter = NetMotionMeter()
        for i in 0..<10 { meter.record(0.02, at: 2.0 + Double(i) / 30) }
        XCTAssertNil(meter.swing(after: 2.0))
    }

    // MARK: - Fusion

    func test_fuse_netConfirmsASettledMake() {
        let fused = ShotEvidence.fuse(result: .make, confidence: 0.8, netSwing: 5)
        XCTAssertEqual(fused.result, .make)
        XCTAssertGreaterThanOrEqual(fused.confidence, 0.9)
    }

    func test_fuse_stillNetFlagsASettledMake() {
        let fused = ShotEvidence.fuse(result: .make, confidence: 0.8, netSwing: 1.0)
        XCTAssertEqual(fused.result, .make)
        XCTAssertLessThan(fused.confidence, HoopTrack.CV.lowConfidence)
    }

    func test_fuse_cleanExitMake_isNotOverruled() {
        XCTAssertEqual(ShotEvidence.fuse(result: .make, confidence: 0.95, netSwing: 1.0).confidence, 0.95)
    }

    func test_fuse_lostBallWithSwingingNet_becomesAFlaggedMake() {
        let fused = ShotEvidence.fuse(result: .miss, confidence: 0.35, netSwing: 4)
        XCTAssertEqual(fused.result, .make)
        XCTAssertLessThan(fused.confidence, HoopTrack.CV.lowConfidence)
    }

    func test_fuse_obviousMiss_isLeftAlone() {
        let fused = ShotEvidence.fuse(result: .miss, confidence: 0.9, netSwing: 6)
        XCTAssertEqual(fused.result, .miss)
        XCTAssertEqual(fused.confidence, 0.9)
    }

    func test_fuse_noEvidence_passesThrough() {
        let fused = ShotEvidence.fuse(result: .miss, confidence: 0.65, netSwing: nil)
        XCTAssertEqual(fused.result, .miss)
        XCTAssertEqual(fused.confidence, 0.65)
    }

    // MARK: - Watching the net

    func test_watch_holdsTheGridThroughSmallWobbles() {
        var watch = NetWatch()
        let first = watch.aim(at: hoop, aspect: 16.0 / 9.0)
        XCTAssertEqual(first.count, 120)
        let wobble = hoop.offsetBy(dx: 0.004, dy: 0.004)
        XCTAssertEqual(watch.aim(at: wobble, aspect: 16.0 / 9.0), first)
        let moved = hoop.offsetBy(dx: 0.03, dy: 0)
        XCTAssertNotEqual(watch.aim(at: moved, aspect: 16.0 / 9.0), first)
    }

    func test_watch_framesWithoutSamplesClearTheMeter() {
        var watch = NetWatch()
        _ = watch.aim(at: hoop, aspect: 16.0 / 9.0)
        var t = 0.0
        for _ in 0..<60 {
            watch.observe([UInt8](repeating: UInt8(t * 30) % 2 == 0 ? 10 : 12, count: 4), at: t)
            t += 1.0 / 30
        }
        XCTAssertNotNil(watch.meter.swing(after: 1.5))
        XCTAssertNil(watch.observe(nil, at: t))
        XCTAssertNil(watch.meter.swing(after: 1.5))
    }

    // MARK: - Holding unsure calls

    private func outcome(_ result: ShotResult, confidence: Double,
                         arrival: Double?, lastSeen: Double = 2.0) -> ShotTracker.Outcome {
        ShotTracker.Outcome(result: result, confidence: confidence,
                            release: .init(box: hoop, time: 1.0, ballDiameter: 0.03),
                            rimArrivalTime: arrival, hoop: hoop, lastSeenTime: lastSeen)
    }

    func test_check_sureCallsPassStraightThrough() {
        var check = NetCheck<Int>()
        let calls = check.submit(outcome(.make, confidence: 0.95, arrival: 2.0), context: 7,
                                 now: 2.3, meter: NetMotionMeter())
        XCTAssertEqual(calls.map(\.result), [.make])
        XCTAssertEqual(calls.first?.context, 7)
        XCTAssertNil(check.heldHoop)
    }

    func test_check_holdsAnUnsureCallUntilTheNetHasSwung() {
        let swinging = meter(base: 0.01, after: 0.06, length: 0.6)
        var check = NetCheck<Void>()
        XCTAssertTrue(check.submit(outcome(.make, confidence: 0.8, arrival: 2.0), context: (),
                                   now: 2.45, meter: swinging).isEmpty)
        XCTAssertEqual(check.heldHoop, hoop)
        XCTAssertNil(check.due(now: 2.6, meter: swinging))
        let call = check.due(now: 2.72, meter: swinging)
        XCTAssertEqual(call?.result, .make)
        XCTAssertGreaterThanOrEqual(call?.confidence ?? 0, 0.9)
        XCTAssertEqual(call?.outcome.confidence, 0.8)      // the tracker's own call is kept
    }

    func test_check_lostBallIsJudgedFromWhenItWasLastSeen() {
        // Lost at 2.0, given up on at 2.9: the net footage is already there.
        let swinging = meter(base: 0.01, after: 0.06, length: 0.6)
        var check = NetCheck<Void>()
        let calls = check.submit(outcome(.miss, confidence: 0.35, arrival: nil, lastSeen: 2.0),
                                 context: (), now: 2.9, meter: swinging)
        XCTAssertEqual(calls.map(\.result), [.make])
        XCTAssertLessThan(calls[0].confidence, HoopTrack.CV.lowConfidence)
    }

    func test_check_aNewCallFlushesTheHeldOne() {
        var check = NetCheck<Int>()
        _ = check.submit(outcome(.make, confidence: 0.7, arrival: 2.0), context: 1,
                         now: 2.45, meter: NetMotionMeter())
        let calls = check.submit(outcome(.miss, confidence: 0.9, arrival: 2.5), context: 2,
                                 now: 2.5, meter: NetMotionMeter())
        XCTAssertEqual(calls.map(\.context), [1, 2])
        XCTAssertEqual(calls[0].confidence, 0.7)            // no footage: unchanged
    }

    func test_check_aNetThatNeverMoves_isIgnored() {
        // Bare rim: two clean makes, net still both times.
        let still = meter(base: 0.01, after: 0.01, length: 0.6)
        var check = NetCheck<Void>()
        XCTAssertNil(check.netResponds)
        for _ in 0..<2 {
            _ = check.submit(outcome(.make, confidence: 0.95, arrival: 2.0), context: (), now: 2.3, meter: still)
            _ = check.due(now: 2.8, meter: still)
        }
        XCTAssertEqual(check.netResponds, false)
        _ = check.submit(outcome(.make, confidence: 0.8, arrival: 2.0), context: (), now: 2.45, meter: still)
        XCTAssertEqual(check.due(now: 2.75, meter: still)?.confidence, 0.8)   // not flagged
    }

    func test_check_aNetThatSwingsOnCleanMakes_isTrusted() {
        let swinging = meter(base: 0.01, after: 0.06, length: 0.6)
        var check = NetCheck<Void>()
        for _ in 0..<2 {
            _ = check.submit(outcome(.make, confidence: 0.95, arrival: 2.0), context: (), now: 2.3, meter: swinging)
            _ = check.due(now: 2.8, meter: swinging)
        }
        XCTAssertEqual(check.netResponds, true)
    }
}
