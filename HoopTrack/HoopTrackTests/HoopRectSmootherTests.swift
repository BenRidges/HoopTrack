// HoopRectSmootherTests.swift
import XCTest
import CoreGraphics
@testable import HoopTrack

final class HoopRectSmootherTests: XCTestCase {

    // MARK: - Initial state

    func test_initialState_isLooking() {
        let smoother = HoopRectSmoother()
        XCTAssertEqual(smoother.state, .looking)
        XCTAssertNil(smoother.smoothedRect)
    }

    // MARK: - First detection

    func test_firstDetection_returnsThatRect_stateBecomesTracking() {
        var smoother = HoopRectSmoother()
        let rect = CGRect(x: 0.45, y: 0.70, width: 0.10, height: 0.08)
        smoother.update(basketRect: rect, timestamp: 0.0)

        XCTAssertEqual(smoother.state, .tracking)
        XCTAssertEqual(smoother.smoothedRect, rect)
    }

    // MARK: - Smoothing

    func test_secondDetection_emaBlendsTowardNewRect() {
        var smoother = HoopRectSmoother(alpha: 0.5)
        let a = CGRect(x: 0.0, y: 0.0, width: 0.10, height: 0.10)
        let b = CGRect(x: 1.0, y: 1.0, width: 0.20, height: 0.20)

        smoother.update(basketRect: a, timestamp: 0.0)
        smoother.update(basketRect: b, timestamp: 0.1)

        // EMA with alpha=0.5 averages a and b exactly.
        let expected = CGRect(x: 0.5, y: 0.5, width: 0.15, height: 0.15)
        XCTAssertEqual(smoother.smoothedRect!.origin.x, expected.origin.x, accuracy: 1e-6)
        XCTAssertEqual(smoother.smoothedRect!.origin.y, expected.origin.y, accuracy: 1e-6)
        XCTAssertEqual(smoother.smoothedRect!.width,    expected.width,    accuracy: 1e-6)
        XCTAssertEqual(smoother.smoothedRect!.height,   expected.height,   accuracy: 1e-6)
    }

    // MARK: - Lost tracking

    func test_noDetectionForLongerThanTimeout_transitionsToLost() {
        var smoother = HoopRectSmoother(lostTimeoutSec: 0.5)
        smoother.update(basketRect: CGRect(x: 0, y: 0, width: 1, height: 1), timestamp: 0.0)
        XCTAssertEqual(smoother.state, .tracking)

        smoother.updateNoDetection(timestamp: 0.6)
        XCTAssertEqual(smoother.state, .lost)
    }

    func test_lostState_retainsLastSmoothedRect() {
        var smoother = HoopRectSmoother(lostTimeoutSec: 0.5)
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        smoother.update(basketRect: rect, timestamp: 0.0)
        smoother.updateNoDetection(timestamp: 0.6)

        XCTAssertEqual(smoother.state, .lost)
        XCTAssertEqual(smoother.smoothedRect, rect)  // last known good rect preserved
    }

    func test_noDetectionShorterThanTimeout_staysTracking() {
        var smoother = HoopRectSmoother(lostTimeoutSec: 0.5)
        smoother.update(basketRect: CGRect(x: 0, y: 0, width: 1, height: 1), timestamp: 0.0)

        smoother.updateNoDetection(timestamp: 0.3)
        XCTAssertEqual(smoother.state, .tracking)
    }

    // MARK: - Recovery

    func test_detectionAfterLost_returnsToTracking_withNewRect() {
        var smoother = HoopRectSmoother(lostTimeoutSec: 0.5)
        smoother.update(basketRect: CGRect(x: 0, y: 0, width: 1, height: 1), timestamp: 0.0)
        smoother.updateNoDetection(timestamp: 0.6)
        XCTAssertEqual(smoother.state, .lost)

        let newRect = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        smoother.update(basketRect: newRect, timestamp: 1.0)

        XCTAssertEqual(smoother.state, .tracking)
        // After a lost-then-seen transition, smoother snaps to the new rect
        // rather than blending with the stale one.
        XCTAssertEqual(smoother.smoothedRect, newRect)
    }

    // MARK: - Reset

    func test_reset_returnsToLooking() {
        var smoother = HoopRectSmoother()
        smoother.update(basketRect: CGRect(x: 0, y: 0, width: 1, height: 1), timestamp: 0.0)
        smoother.reset()

        XCTAssertEqual(smoother.state, .looking)
        XCTAssertNil(smoother.smoothedRect)
    }
}
