// HoopTrackTests/SetupCheckTests.swift
// The live setup tips, judged from the rim box alone.

import XCTest
@testable import HoopTrack
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class SetupCheckTests: XCTestCase {

    /// A rim `width` of the frame wide, centred at (x, y), Vision-normalised.
    private func rim(width: Double = 0.047, x: Double = 0.5, y: Double = 0.6) -> CGRect {
        let height = width * 16 / 9 * 0.55     // a rim seen from behind and a little below
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    func test_theRealClipsSetups_areGood() {
        // somorin cam1 / cam2 and alec 07-11: every usable shot called right.
        XCTAssertEqual(SetupCheck.advice(hoop: CGRect(x: 0.438, y: 0.776, width: 0.047, height: 0.046)), .good)
        XCTAssertEqual(SetupCheck.advice(hoop: CGRect(x: 0.63, y: 0.79, width: 0.047, height: 0.046)), .good)
        XCTAssertEqual(SetupCheck.advice(hoop: CGRect(x: 0.60, y: 0.59, width: 0.046, height: 0.045)), .good)
    }

    func test_aBigRim_isTooClose() {
        XCTAssertEqual(SetupCheck.advice(hoop: rim(width: 0.14, y: 0.5)), .tooClose)
    }

    func test_aTinyRim_isTooFar() {
        XCTAssertEqual(SetupCheck.advice(hoop: rim(width: 0.02)), .tooFar)
    }

    func test_aRimRunningOffTheEdge_isCutOff() {
        XCTAssertEqual(SetupCheck.advice(hoop: CGRect(x: 0.97, y: 0.6, width: 0.03, height: 0.04)), .rimCutOff)
        XCTAssertEqual(SetupCheck.advice(hoop: CGRect(x: 0.5, y: 0.96, width: 0.05, height: 0.04)), .rimCutOff)
    }

    func test_noRoomAboveTheRim_tiltUp() {
        // Top at 0.93: 0.07 of the height is ~0.8 rim widths of headroom.
        XCTAssertEqual(SetupCheck.advice(hoop: CGRect(x: 0.45, y: 0.89, width: 0.047, height: 0.04)), .tiltUp)
    }

    func test_aLowRim_tiltDown() {
        XCTAssertEqual(SetupCheck.advice(hoop: rim(y: 0.2)), .tiltDown)
    }

    func test_aRimNearASide_turnsTowardsIt() {
        XCTAssertEqual(SetupCheck.advice(hoop: rim(x: 0.08)), .turnLeft)
        XCTAssertEqual(SetupCheck.advice(hoop: rim(x: 0.93)), .turnRight)
    }

    func test_cutOffOutranksSize() {
        // Too close *and* off the edge: the cut-off rim is the first fix.
        XCTAssertEqual(SetupCheck.advice(hoop: CGRect(x: 0.9, y: 0.4, width: 0.2, height: 0.2)), .rimCutOff)
    }

    func test_anEmptyBox_isNotGood() {
        XCTAssertEqual(SetupCheck.advice(hoop: .zero), .rimCutOff)
    }
}
