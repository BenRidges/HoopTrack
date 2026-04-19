import XCTest
import CoreGraphics
@testable import HoopTrack

final class AppearanceExtractionTests: XCTestCase {

    // MARK: - normalizedHistogram

    func test_normalizedHistogram_sumsToOne() {
        let raw: [Float] = [10, 20, 30, 40]
        let out = AppearanceExtraction.normalizedHistogram(raw)
        XCTAssertEqual(out.reduce(0, +), 1.0, accuracy: 1e-5)
        XCTAssertEqual(out[0], 0.1, accuracy: 1e-5)
        XCTAssertEqual(out[3], 0.4, accuracy: 1e-5)
    }

    func test_normalizedHistogram_allZeros_returnsUniform() {
        let out = AppearanceExtraction.normalizedHistogram([0, 0, 0, 0])
        XCTAssertEqual(out.reduce(0, +), 1.0, accuracy: 1e-5)
        XCTAssertEqual(out[0], out[1])
        XCTAssertEqual(out[1], out[2])
    }

    // MARK: - upperBodyBox

    func test_upperBodyBox_fromStandardKeypoints() {
        let leftShoulder  = CGPoint(x: 0.45, y: 0.30)
        let rightShoulder = CGPoint(x: 0.55, y: 0.30)
        let leftHip       = CGPoint(x: 0.46, y: 0.55)
        let rightHip      = CGPoint(x: 0.54, y: 0.55)

        let box = AppearanceExtraction.upperBodyBox(
            leftShoulder: leftShoulder,
            rightShoulder: rightShoulder,
            leftHip: leftHip,
            rightHip: rightHip
        )

        XCTAssertEqual(box.minX, 0.45, accuracy: 1e-5)
        XCTAssertEqual(box.width, 0.10, accuracy: 1e-5)
        XCTAssertEqual(box.minY, 0.30, accuracy: 1e-5)
        XCTAssertEqual(box.height, 0.25, accuracy: 1e-5)
    }

    // MARK: - heightRatio

    func test_heightRatio_fromNoseToAnkles() {
        let nose   = CGPoint(x: 0.5, y: 0.15)
        let lAnkle = CGPoint(x: 0.48, y: 0.90)
        let rAnkle = CGPoint(x: 0.52, y: 0.88)
        let ratio = AppearanceExtraction.heightRatio(
            nose: nose, leftAnkle: lAnkle, rightAnkle: rAnkle
        )
        XCTAssertEqual(ratio, 0.75, accuracy: 1e-5)
    }
}
