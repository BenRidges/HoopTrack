// HoopTrackTests/DetectionRegionTests.swift

import XCTest
@testable import HoopTrack
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class DetectionRegionTests: XCTestCase {

    private let width = 1280.0, height = 720.0
    /// A far hoop: 40 px wide, near the top centre.
    private let hoop = CGRect(x: 0.484, y: 0.70, width: 0.03125, height: 0.04)

    private func pixelSize(_ r: CGRect) -> (w: Double, h: Double) {
        (Double(r.width) * width, Double(r.height) * height)
    }

    /// Edge comparison with a tolerance (CGRect.contains compares a
    /// recomputed union exactly, so rounding can make it fail).
    private func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        let e: CGFloat = 1e-9
        return inner.minX >= outer.minX - e && inner.maxX <= outer.maxX + e
            && inner.minY >= outer.minY - e && inner.maxY <= outer.maxY + e
    }

    func test_noBall_usesFullFrame() {
        XCTAssertNil(DetectionRegion.around(hoop: hoop, ball: nil, frameWidth: width, frameHeight: height))
    }

    func test_cropIsSquareInPixels_andHoldsHoopAndBall() throws {
        let ball = CGRect(x: 0.52, y: 0.80, width: 0.012, height: 0.021)
        let region = try XCTUnwrap(DetectionRegion.around(hoop: hoop, ball: ball,
                                                          frameWidth: width, frameHeight: height))
        let size = pixelSize(region)
        XCTAssertEqual(size.w, size.h, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(size.w, 448 - 0.5)
        XCTAssertTrue(contains(region, hoop))
        XCTAssertTrue(contains(region, ball))
        XCTAssertTrue(contains(CGRect(x: 0, y: 0, width: 1, height: 1), region))
    }

    func test_cropIsShiftedInsideTheFrame_nearAnEdge() throws {
        let edgeHoop = CGRect(x: 0.94, y: 0.88, width: 0.03125, height: 0.04)
        let ball = CGRect(x: 0.95, y: 0.93, width: 0.012, height: 0.021)
        let region = try XCTUnwrap(DetectionRegion.around(hoop: edgeHoop, ball: ball,
                                                          frameWidth: width, frameHeight: height))
        XCTAssertLessThanOrEqual(Double(region.maxX), 1 + 1e-9)
        XCTAssertLessThanOrEqual(Double(region.maxY), 1 + 1e-9)
        XCTAssertTrue(contains(region, edgeHoop))
    }

    func test_ballFarFromHoop_fallsBackToFullFrame() {
        // Ball still down by the shooter, bottom-left of the frame.
        let ball = CGRect(x: 0.05, y: 0.05, width: 0.05, height: 0.09)
        XCTAssertNil(DetectionRegion.around(hoop: hoop, ball: ball, frameWidth: width, frameHeight: height))
    }

    func test_roundTrip_regionRelativeBoxMapsBackToFrame() {
        let region = CGRect(x: 0.3, y: 0.2, width: 0.35, height: 0.6)
        let inRegion = CGRect(x: 0.5, y: 0.25, width: 0.1, height: 0.2)
        let full = DetectionRegion.toFullFrame(inRegion, from: region)
        XCTAssertEqual(Double(full.minX), 0.3 + 0.5 * 0.35, accuracy: 1e-9)
        XCTAssertEqual(Double(full.minY), 0.2 + 0.25 * 0.6, accuracy: 1e-9)
        XCTAssertEqual(Double(full.width), 0.035, accuracy: 1e-9)
        XCTAssertEqual(Double(full.height), 0.12, accuracy: 1e-9)
    }

    func test_fullFrameRegion_isIdentity() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(DetectionRegion.toFullFrame(box, from: CGRect(x: 0, y: 0, width: 1, height: 1)), box)
    }
}
