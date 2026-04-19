import XCTest
@testable import HoopTrack

final class AppearanceDescriptorTests: XCTestCase {

    func test_roundTripJSONEncoding_preservesAllFields() throws {
        let original = AppearanceDescriptor(
            torsoHueHistogram: [0.1, 0.2, 0.1, 0.05, 0.05, 0.2, 0.15, 0.15],
            torsoValueHistogram: [0.25, 0.25, 0.25, 0.25],
            heightRatio: 0.42,
            upperBodyAspect: 0.6,
            schemaVersion: 1
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppearanceDescriptor.self, from: data)

        XCTAssertEqual(decoded.torsoHueHistogram, original.torsoHueHistogram)
        XCTAssertEqual(decoded.torsoValueHistogram, original.torsoValueHistogram)
        XCTAssertEqual(decoded.heightRatio, original.heightRatio, accuracy: 1e-6)
        XCTAssertEqual(decoded.upperBodyAspect, original.upperBodyAspect, accuracy: 1e-6)
        XCTAssertEqual(decoded.schemaVersion, original.schemaVersion)
    }

    func test_isWellFormed_trueForValidDescriptor() {
        let valid = AppearanceDescriptor(
            torsoHueHistogram: Array(repeating: 0.125, count: 8),
            torsoValueHistogram: Array(repeating: 0.25, count: 4),
            heightRatio: 0.5,
            upperBodyAspect: 0.65,
            schemaVersion: 1
        )
        XCTAssertTrue(valid.isWellFormed)
    }

    func test_isWellFormed_falseForWrongHueBinCount() {
        let bad = AppearanceDescriptor(
            torsoHueHistogram: [0.5, 0.5],
            torsoValueHistogram: Array(repeating: 0.25, count: 4),
            heightRatio: 0.5,
            upperBodyAspect: 0.65,
            schemaVersion: 1
        )
        XCTAssertFalse(bad.isWellFormed)
    }

    func test_isWellFormed_falseForUnnormalisedHistogram() {
        let bad = AppearanceDescriptor(
            torsoHueHistogram: Array(repeating: 1.0, count: 8),
            torsoValueHistogram: Array(repeating: 0.25, count: 4),
            heightRatio: 0.5,
            upperBodyAspect: 0.65,
            schemaVersion: 1
        )
        XCTAssertFalse(bad.isWellFormed)
    }
}
