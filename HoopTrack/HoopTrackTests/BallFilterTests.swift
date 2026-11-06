// HoopTrackTests/BallFilterTests.swift

import XCTest
@testable import HoopTrack

final class BallFilterTests: XCTestCase {

    private func makeFilter(at p: BallFilter.Point, time: Double = 0) -> BallFilter {
        BallFilter(at: p, time: time, accelerationSD: 2.0, measurementSD: 0.01, initialVelocitySD: 2.0)
    }

    func test_learnsVelocity_fromSteadyMotion() {
        var filter = makeFilter(at: .init(x: 0, y: 0))
        for i in 1...20 {
            let t = Double(i) / 60
            filter.update(with: .init(x: 0.6 * t, y: 1.2 * t), at: t)
        }
        XCTAssertEqual(filter.velocity.x, 0.6, accuracy: 0.05)
        XCTAssertEqual(filter.velocity.y, 1.2, accuracy: 0.05)
        let ahead = filter.predicted(at: 21.0 / 60)
        XCTAssertEqual(ahead.y, 1.2 * 21 / 60, accuracy: 0.01)
    }

    func test_predictionBridgesMissedFrames() {
        var filter = makeFilter(at: .init(x: 0.5, y: 0.2))
        for i in 1...15 {
            let t = Double(i) / 60
            filter.update(with: .init(x: 0.5, y: 0.2 + 1.0 * t), at: t)
        }
        // Three frames with no detection, then the ball is where it should be.
        let t = 18.0 / 60
        let truth = BallFilter.Point(x: 0.5, y: 0.2 + 1.0 * t)
        XCTAssertLessThan(filter.surprise(of: truth, at: t), 2.0)
        XCTAssertEqual(filter.predicted(at: t).y, truth.y, accuracy: 0.01)
    }

    func test_gateWidensWhileUnseen() {
        var filter = makeFilter(at: .init(x: 0.5, y: 0.5))
        for i in 1...10 { filter.update(with: .init(x: 0.5, y: 0.5), at: Double(i) / 60) }
        let offset = BallFilter.Point(x: 0.55, y: 0.5)
        let soon = filter.surprise(of: offset, at: 11.0 / 60)
        let later = filter.surprise(of: offset, at: 40.0 / 60)
        XCTAssertGreaterThan(soon, later, "the same offset should be less surprising after a gap")
    }

    func test_farJump_isVerySurprising() {
        var filter = makeFilter(at: .init(x: 0.5, y: 0.3))
        for i in 1...10 {
            let t = Double(i) / 60
            filter.update(with: .init(x: 0.5, y: 0.3 + 0.8 * t), at: t)
        }
        let decoy = BallFilter.Point(x: 0.9, y: 0.1)
        XCTAssertGreaterThan(filter.surprise(of: decoy, at: 11.0 / 60), 10)
    }

    func test_smoothsMeasurementNoise() {
        var filter = makeFilter(at: .init(x: 0, y: 0))
        var rawError = 0.0, filteredError = 0.0
        // Deterministic ±noise around a straight line.
        for i in 1...60 {
            let t = Double(i) / 60
            let truth = 0.9 * t
            let noise = (i % 2 == 0 ? 1.0 : -1.0) * 0.012
            filter.update(with: .init(x: 0, y: truth + noise), at: t)
            if i > 20 {
                rawError += abs(noise)
                filteredError += abs(filter.position.y - truth)
            }
        }
        XCTAssertLessThan(filteredError, rawError * 0.6)
    }
}
