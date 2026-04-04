import XCTest
import AVFoundation
@testable import HoopTrack

final class ShotScienceCalculatorTests: XCTestCase {

    // MARK: - releaseAngle

    func test_releaseAngle_typicalAscendingShot_returnsPositiveAngle() {
        let detections = [
            BallDetection(boundingBox: CGRect(x: 0.30, y: 0.40, width: 0.05, height: 0.05),
                          confidence: 0.9,
                          frameTimestamp: CMTime(value: 0, timescale: 60)),
            BallDetection(boundingBox: CGRect(x: 0.34, y: 0.47, width: 0.05, height: 0.05),
                          confidence: 0.9,
                          frameTimestamp: CMTime(value: 1, timescale: 60)),
        ]
        let angle = ShotScienceCalculator.releaseAngle(trajectory: detections)
        XCTAssertNotNil(angle)
        XCTAssertTrue(angle! > 30 && angle! < 80, "Expected shooting arc angle, got \(angle!)")
    }

    func test_releaseAngle_singleDetection_returnsNil() {
        let detections = [
            BallDetection(boundingBox: CGRect(x: 0.3, y: 0.4, width: 0.05, height: 0.05),
                          confidence: 0.9,
                          frameTimestamp: .zero),
        ]
        XCTAssertNil(ShotScienceCalculator.releaseAngle(trajectory: detections))
    }

    func test_releaseAngle_emptyTrajectory_returnsNil() {
        XCTAssertNil(ShotScienceCalculator.releaseAngle(trajectory: []))
    }

    // MARK: - releaseTime

    func test_releaseTime_thirtyFramesAt60fps_returns500ms() {
        let t1 = CMTime(value: 0,  timescale: 60)
        let t2 = CMTime(value: 30, timescale: 60)
        let detections = [
            BallDetection(boundingBox: .zero, confidence: 0.9, frameTimestamp: t1),
            BallDetection(boundingBox: .zero, confidence: 0.9, frameTimestamp: t2),
        ]
        let time = ShotScienceCalculator.releaseTime(trajectory: detections)
        XCTAssertNotNil(time)
        XCTAssertEqual(time!, 500.0, accuracy: 1.0)
    }

    func test_releaseTime_singleDetection_returnsNil() {
        let detections = [
            BallDetection(boundingBox: .zero, confidence: 0.9, frameTimestamp: .zero),
        ]
        XCTAssertNil(ShotScienceCalculator.releaseTime(trajectory: detections))
    }

    // MARK: - shotSpeed

    func test_shotSpeed_knownDisplacement_returnsPositiveSpeed() {
        let t1 = CMTime(value: 0, timescale: 60)
        let t2 = CMTime(value: 1, timescale: 60)
        let detections = [
            BallDetection(boundingBox: CGRect(x: 0.00, y: 0.5, width: 0.05, height: 0.05),
                          confidence: 0.9, frameTimestamp: t1),
            BallDetection(boundingBox: CGRect(x: 0.10, y: 0.5, width: 0.05, height: 0.05),
                          confidence: 0.9, frameTimestamp: t2),
        ]
        let speed = ShotScienceCalculator.shotSpeed(trajectory: detections, hoopRectWidth: 0.1)
        XCTAssertNotNil(speed)
        XCTAssertTrue(speed! > 0)
    }

    func test_shotSpeed_singleDetection_returnsNil() {
        let detections = [BallDetection(boundingBox: .zero, confidence: 0.9, frameTimestamp: .zero)]
        XCTAssertNil(ShotScienceCalculator.shotSpeed(trajectory: detections, hoopRectWidth: 0.1))
    }

    func test_shotSpeed_zeroHoopWidth_returnsNil() {
        let t1 = CMTime(value: 0, timescale: 60)
        let t2 = CMTime(value: 1, timescale: 60)
        let detections = [
            BallDetection(boundingBox: .zero, confidence: 0.9, frameTimestamp: t1),
            BallDetection(boundingBox: CGRect(x: 0.1, y: 0, width: 0.05, height: 0.05),
                          confidence: 0.9, frameTimestamp: t2),
        ]
        XCTAssertNil(ShotScienceCalculator.shotSpeed(trajectory: detections, hoopRectWidth: 0))
    }

    // MARK: - consistencyScore

    func test_consistencyScore_uniformAngles_returnsZero() {
        let score = ShotScienceCalculator.consistencyScore(releaseAngles: [45, 45, 45, 45])
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 0.0, accuracy: 0.001)
    }

    func test_consistencyScore_singleAngle_returnsNil() {
        XCTAssertNil(ShotScienceCalculator.consistencyScore(releaseAngles: [45]))
    }

    func test_consistencyScore_emptyAngles_returnsNil() {
        XCTAssertNil(ShotScienceCalculator.consistencyScore(releaseAngles: []))
    }

    func test_consistencyScore_spreadAngles_returnsPositiveStdDev() {
        let score = ShotScienceCalculator.consistencyScore(releaseAngles: [40, 45, 50, 55, 60])
        XCTAssertNotNil(score)
        XCTAssertTrue(score! > 0)
    }

    // MARK: - legAngleGeometry

    func test_legAngleGeometry_straightLeg_returns180Degrees() {
        let angle = ShotScienceCalculator.legAngleGeometry(
            hip:   CGPoint(x: 0.5, y: 0.8),
            knee:  CGPoint(x: 0.5, y: 0.5),
            ankle: CGPoint(x: 0.5, y: 0.2)
        )
        XCTAssertNotNil(angle)
        XCTAssertEqual(angle!, 180.0, accuracy: 0.5)
    }

    func test_legAngleGeometry_rightAngle_returns90Degrees() {
        let angle = ShotScienceCalculator.legAngleGeometry(
            hip:   CGPoint(x: 0.5, y: 0.8),
            knee:  CGPoint(x: 0.5, y: 0.5),
            ankle: CGPoint(x: 0.8, y: 0.5)
        )
        XCTAssertNotNil(angle)
        XCTAssertEqual(angle!, 90.0, accuracy: 0.5)
    }

    // MARK: - verticalJumpGeometry

    func test_verticalJumpGeometry_standingPosition_returnsNilOrNearZero() {
        let result = ShotScienceCalculator.verticalJumpGeometry(
            hipY: 0.55, ankleY: 0.05, shoulderY: 0.90
        )
        if let jump = result { XCTAssertTrue(jump < 5.0) }
    }

    func test_verticalJumpGeometry_jumpedPosition_returnsPositiveCm() {
        let result = ShotScienceCalculator.verticalJumpGeometry(
            hipY: 0.68, ankleY: 0.05, shoulderY: 0.95
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result! > 5.0)
    }

    func test_verticalJumpGeometry_bodyNotFullyVisible_returnsNil() {
        XCTAssertNil(ShotScienceCalculator.verticalJumpGeometry(
            hipY: 0.5, ankleY: 0.48, shoulderY: 0.52
        ))
    }
}
