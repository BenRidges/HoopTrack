// HoopTrackTests/ShotScienceCalculatorTests.swift
import XCTest
@testable import HoopTrack
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class ShotScienceCalculatorTests: XCTestCase {

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

    func test_consistencyScore_spreadAngles_returnsPopulationStdDev() {
        let score = ShotScienceCalculator.consistencyScore(releaseAngles: [40, 45, 50, 55, 60])
        XCTAssertEqual(score!, 7.071, accuracy: 0.01)
    }

    // MARK: - ShotPhysics

    /// A free throw (4.19 m) launched at 50° from 2.2 m reaches rim height
    /// after ~0.92 s. Feeding that flight time back must recover ~50°.
    func test_launch_freeThrowFlightTime_recoversFiftyDegrees() {
        let launch = ShotPhysics.launch(horizontalDistanceM: 4.19, flightTime: 0.92)
        XCTAssertNotNil(launch)
        XCTAssertEqual(launch!.angleDeg, 50, accuracy: 1.5)
        XCTAssertEqual(launch!.speedMph, 15.9, accuracy: 1.0)
    }

    func test_launch_longerFlightSameDistance_isHigherArc() {
        let flat = ShotPhysics.launch(horizontalDistanceM: 5, flightTime: 0.8)!
        let high = ShotPhysics.launch(horizontalDistanceM: 5, flightTime: 1.2)!
        XCTAssertGreaterThan(high.angleDeg, flat.angleDeg)
    }

    func test_launch_implausibleInputs_returnNil() {
        XCTAssertNil(ShotPhysics.launch(horizontalDistanceM: 5, flightTime: 0.1))
        XCTAssertNil(ShotPhysics.launch(horizontalDistanceM: 5, flightTime: 4))
        XCTAssertNil(ShotPhysics.launch(horizontalDistanceM: 0.2, flightTime: 1))
        XCTAssertNil(ShotPhysics.launch(horizontalDistanceM: .nan, flightTime: 1))
    }

    // MARK: - CourtPositionEstimator

    private let fov = 68.0
    private var focal: Double { 0.5 / tan(fov * .pi / 360) }

    /// Apparent width (image-width units) of an object `size` metres across at `depth`.
    private func width(_ size: Double, at depth: Double) -> Double { focal * size / depth }

    func test_estimate_shooterStraightBehindAtFreeThrowDistance() {
        // Rim 9 m from the camera, shooter 4.19 m in front of the rim on the same line.
        let rimW = width(CourtPositionEstimator.rimDiameterM, at: 9)
        let ballW = width(CourtPositionEstimator.ballDiameterM, at: 9 - 4.19)
        let rim = CGRect(x: 0.5 - rimW / 2, y: 0.7, width: rimW, height: rimW * 0.8)
        let ball = CGRect(x: 0.5 - ballW / 2, y: 0.5, width: ballW, height: ballW * 16 / 9)

        let estimate = CourtPositionEstimator.estimate(ballBox: ball, ballDiameter: ballW,
                                                       rimBox: rim, horizontalFOV: fov)
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate!.depthM, 4.19, accuracy: 0.05)
        XCTAssertEqual(estimate!.lateralM, 0, accuracy: 0.05)

        let position = CourtPositionEstimator.courtPosition(for: estimate!)
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: position.courtX, courtY: position.courtY), .freeThrow)
    }

    func test_estimate_shooterOffToTheRight_mapsRightOfBasket() {
        let rimDepth = 9.0, ballDepth = 5.0, lateral = 2.0
        let rimW = width(CourtPositionEstimator.rimDiameterM, at: rimDepth)
        let ballW = width(CourtPositionEstimator.ballDiameterM, at: ballDepth)
        let ballCentreX = 0.5 + lateral * focal / ballDepth
        let rim = CGRect(x: 0.5 - rimW / 2, y: 0.7, width: rimW, height: rimW)
        let ball = CGRect(x: ballCentreX - ballW / 2, y: 0.5, width: ballW, height: ballW)

        let estimate = CourtPositionEstimator.estimate(ballBox: ball, ballDiameter: ballW,
                                                       rimBox: rim, horizontalFOV: fov)!
        XCTAssertEqual(estimate.lateralM, 2, accuracy: 0.05)
        XCTAssertEqual(estimate.depthM, 4, accuracy: 0.05)
        XCTAssertGreaterThan(CourtPositionEstimator.courtPosition(for: estimate).courtX, 0.5)
    }

    func test_estimate_degenerateSizes_returnNil() {
        let rim = CGRect(x: 0.45, y: 0.7, width: 0.05, height: 0.04)
        XCTAssertNil(CourtPositionEstimator.estimate(ballBox: .zero, ballDiameter: 0, rimBox: rim))
        XCTAssertNil(CourtPositionEstimator.estimate(ballBox: rim, ballDiameter: 0.02, rimBox: .zero))
    }
}
