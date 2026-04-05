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
