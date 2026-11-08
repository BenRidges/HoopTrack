// HoopTrackTests/SessionTargetTests.swift
// The live screen's "something to chase".

import XCTest
@testable import HoopTrack

final class SessionTargetTests: XCTestCase {

    func test_aNamedDrill_racesYourBestInIt() {
        XCTAssertEqual(SessionTarget.choose(drillBest: 18, isNamedDrill: true, fgGoal: 50, mostMakes: 40),
                       .makes(best: 18))
        XCTAssertNil(SessionTarget.choose(drillBest: nil, isNamedDrill: true, fgGoal: 50, mostMakes: 40),
                     "a first go at a drill has nothing to race")
    }

    func test_aFreeSession_racesYourGoal_elseYourMostMakes() {
        XCTAssertEqual(SessionTarget.choose(drillBest: nil, isNamedDrill: false, fgGoal: 45, mostMakes: 40),
                       .percent(goal: 45))
        XCTAssertEqual(SessionTarget.choose(drillBest: nil, isNamedDrill: false, fgGoal: nil, mostMakes: 40),
                       .makes(best: 40))
        XCTAssertNil(SessionTarget.choose(drillBest: nil, isNamedDrill: false, fgGoal: nil, mostMakes: 0))
    }

    func test_makes_lineCountsDownToANewBest() {
        let target = SessionTarget.makes(best: 18)
        XCTAssertEqual(target.line(makes: 12, attempts: 20), "Best 18 · 7 to beat")
        XCTAssertEqual(target.line(makes: 18, attempts: 30), "Best 18 · 1 to beat")
        XCTAssertFalse(target.isMet(makes: 18, attempts: 30), "equal isn't beaten")
        XCTAssertEqual(target.line(makes: 19, attempts: 31), "New best")
        XCTAssertTrue(target.isMet(makes: 19, attempts: 31))
    }

    func test_percent_waitsForAFewShots() {
        let target = SessionTarget.percent(goal: 50)
        XCTAssertEqual(target.line(makes: 3, attempts: 3), "Goal 50%", "three from three says nothing yet")
        XCTAssertEqual(target.line(makes: 3, attempts: 6), "Goal 50% · on target")
        XCTAssertEqual(target.line(makes: 2, attempts: 6), "Goal 50%")
    }
}
