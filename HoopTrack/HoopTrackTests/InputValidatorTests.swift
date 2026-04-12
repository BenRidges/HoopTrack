import XCTest
@testable import HoopTrack

final class InputValidatorTests: XCTestCase {

    // MARK: - Release angle

    func test_releaseAngle_validRange() {
        XCTAssertTrue(InputValidator.isValidReleaseAngle(45.0))
        XCTAssertTrue(InputValidator.isValidReleaseAngle(0.0))
        XCTAssertTrue(InputValidator.isValidReleaseAngle(90.0))
    }

    func test_releaseAngle_outOfRange() {
        XCTAssertFalse(InputValidator.isValidReleaseAngle(-1.0))
        XCTAssertFalse(InputValidator.isValidReleaseAngle(91.0))
        XCTAssertFalse(InputValidator.isValidReleaseAngle(Double.nan))
    }

    // MARK: - Jump height

    func test_jumpHeight_validRange() {
        XCTAssertTrue(InputValidator.isValidJumpHeight(50.0))
        XCTAssertTrue(InputValidator.isValidJumpHeight(0.0))
        XCTAssertTrue(InputValidator.isValidJumpHeight(120.0))
    }

    func test_jumpHeight_outOfRange() {
        XCTAssertFalse(InputValidator.isValidJumpHeight(-5.0))
        XCTAssertFalse(InputValidator.isValidJumpHeight(121.0))
        XCTAssertFalse(InputValidator.isValidJumpHeight(Double.infinity))
    }

    // MARK: - Court coordinates

    func test_courtCoordinate_validRange() {
        XCTAssertTrue(InputValidator.isValidCourtCoordinate(0.0))
        XCTAssertTrue(InputValidator.isValidCourtCoordinate(0.5))
        XCTAssertTrue(InputValidator.isValidCourtCoordinate(1.0))
    }

    func test_courtCoordinate_outOfRange() {
        XCTAssertFalse(InputValidator.isValidCourtCoordinate(-0.01))
        XCTAssertFalse(InputValidator.isValidCourtCoordinate(1.01))
        XCTAssertFalse(InputValidator.isValidCourtCoordinate(Double.nan))
    }

    // MARK: - Profile name

    func test_profileName_valid() {
        XCTAssertEqual(InputValidator.sanitisedProfileName("  LeBron James  "), "LeBron James")
        XCTAssertEqual(InputValidator.sanitisedProfileName("Ben"), "Ben")
    }

    func test_profileName_tooShort_returnsNil() {
        XCTAssertNil(InputValidator.sanitisedProfileName(""))
        XCTAssertNil(InputValidator.sanitisedProfileName("   "))
    }

    func test_profileName_tooLong_returnsNil() {
        let long = String(repeating: "A", count: 51)
        XCTAssertNil(InputValidator.sanitisedProfileName(long))
    }

    func test_profileName_stripsControlCharacters() {
        XCTAssertEqual(InputValidator.sanitisedProfileName("Ben\u{0000}Ridges"), "BenRidges")
    }
}
