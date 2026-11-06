import XCTest
@testable import HoopTrack

final class DribbleCalculatorTests: XCTestCase {

    // MARK: - dribblesPerSecond

    func test_dribblesPerSecond_tenDribblesInTwoSeconds_returnsFive() {
        let result = DribbleCalculator.dribblesPerSecond(count: 10, durationSec: 2.0)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 5.0, accuracy: 0.001)
    }

    func test_dribblesPerSecond_zeroDuration_returnsNil() {
        XCTAssertNil(DribbleCalculator.dribblesPerSecond(count: 5, durationSec: 0))
    }

    func test_dribblesPerSecond_zeroDribbles_returnsZero() {
        let result = DribbleCalculator.dribblesPerSecond(count: 0, durationSec: 3.0)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 0.0, accuracy: 0.001)
    }

    // MARK: - handBalance

    func test_handBalance_equalHands_returnsHalf() {
        let result = DribbleCalculator.handBalance(leftCount: 10, rightCount: 10)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 0.5, accuracy: 0.001)
    }

    func test_handBalance_allLeftHand_returnsOne() {
        let result = DribbleCalculator.handBalance(leftCount: 10, rightCount: 0)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 1.0, accuracy: 0.001)
    }

    func test_handBalance_allRightHand_returnsZero() {
        let result = DribbleCalculator.handBalance(leftCount: 0, rightCount: 10)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 0.0, accuracy: 0.001)
    }

    func test_handBalance_bothZero_returnsNil() {
        XCTAssertNil(DribbleCalculator.handBalance(leftCount: 0, rightCount: 0))
    }

    // MARK: - comboCount

    func test_comboCount_noSwitches_returnsZero() {
        let history: [DribbleCalculator.HandSide] = [.right, .right, .right, .right]
        XCTAssertEqual(DribbleCalculator.comboCount(handHistory: history), 0)
    }

    func test_comboCount_singleSwitch_returnsOne() {
        let history: [DribbleCalculator.HandSide] = [.right, .right, .left, .left]
        XCTAssertEqual(DribbleCalculator.comboCount(handHistory: history), 1)
    }

    func test_comboCount_threeAlternatingSwitches_returnsThree() {
        let history: [DribbleCalculator.HandSide] = [.right, .left, .right, .left]
        XCTAssertEqual(DribbleCalculator.comboCount(handHistory: history), 3)
    }

    func test_comboCount_emptyHistory_returnsZero() {
        XCTAssertEqual(DribbleCalculator.comboCount(handHistory: []), 0)
    }
}

// MARK: - WristBounceDetector

final class WristBounceDetectorTests: XCTestCase {

    /// Wrist oscillating `amplitude` torso-lengths at `hz`, sampled at 30 fps for `seconds`.
    private func count(amplitude: Double, hz: Double = 3, seconds: Double = 4,
                       noise: Double = 0) -> Int {
        var detector = WristBounceDetector()
        let torso = 0.3
        var bounces = 0
        var i = 0
        while Double(i) / 30 < seconds {
            let t = Double(i) / 30
            let jitter = noise * (i.isMultiple(of: 2) ? 1 : -1)
            let y = 0.4 + amplitude * torso * 0.5 * cos(2 * .pi * hz * t) + jitter * torso
            if detector.update(y: y, torso: torso) { bounces += 1 }
            i += 1
        }
        return bounces
    }

    func test_realDribbles_areCounted() {
        // 3 dribbles/s for 4 s → 12, give or take the first half-cycle.
        let n = count(amplitude: 0.5)
        XCTAssertTrue((11...12).contains(n), "got \(n)")
    }

    func test_smallWobble_isIgnored() {
        XCTAssertEqual(count(amplitude: 0.06), 0)
    }

    func test_frameJitter_isIgnored() {
        XCTAssertEqual(count(amplitude: 0, noise: 0.04), 0)
    }

    func test_jitterOnTopOfRealDribbles_doesNotDoubleCount() {
        let n = count(amplitude: 0.5, noise: 0.03)
        XCTAssertTrue((11...12).contains(n), "got \(n)")
    }
}
