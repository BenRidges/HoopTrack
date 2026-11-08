// HoopTrackTests/DrillPlanTests.swift
// Named drills' steps, worked out from the attempt count.

import XCTest
@testable import HoopTrack

final class DrillPlanTests: XCTestCase {

    func test_onlyStepDrillsHavePlans() {
        XCTAssertNotNil(DrillPlan.plan(for: .aroundTheArc))
        XCTAssertNotNil(DrillPlan.plan(for: .midSideMid))
        XCTAssertNotNil(DrillPlan.plan(for: .freethrowChallenge))
        XCTAssertNil(DrillPlan.plan(for: .fiveMinEndurance))
        XCTAssertNil(DrillPlan.plan(for: .mikanDrill))
        XCTAssertNil(DrillPlan.plan(for: .crossoverSeries))
    }

    func test_aroundTheArc_fiveSpotsOfFive() throws {
        let plan = try XCTUnwrap(DrillPlan.plan(for: .aroundTheArc))
        XCTAssertEqual(plan.totalShots, 25)

        let start = plan.progress(after: 0)
        XCTAssertEqual(start.line, "Spot 1 of 5 · Right corner · 5 to go")

        let second = plan.progress(after: 7)
        XCTAssertEqual(second.line, "Spot 2 of 5 · Right wing · 3 to go")

        XCTAssertEqual(plan.progress(after: 5).spot, "Right wing", "five done: on to the next spot")
        XCTAssertEqual(plan.progress(after: 24).line, "Spot 5 of 5 · Left corner · 1 to go")
    }

    func test_aroundTheArc_finishesAfterTheLastSpot() throws {
        let plan = try XCTUnwrap(DrillPlan.plan(for: .aroundTheArc))
        XCTAssertFalse(plan.progress(after: 24).isFinished)
        let done = plan.progress(after: 25)
        XCTAssertTrue(done.isFinished)
        XCTAssertEqual(done.line, "Drill done")
        XCTAssertTrue(plan.progress(after: 31).isFinished, "extra shots don't wrap round")
    }

    func test_freeThrows_repeatInSetsOfTen() throws {
        let plan = try XCTUnwrap(DrillPlan.plan(for: .freethrowChallenge))
        XCTAssertEqual(plan.progress(after: 0).line, "Set 1 · Free-throw line · 10 to go")
        XCTAssertEqual(plan.progress(after: 13).line, "Set 2 · Free-throw line · 7 to go")
        XCTAssertFalse(plan.progress(after: 100).isFinished)
    }

    func test_sameStep_ignoresShotsWithinIt() throws {
        let plan = try XCTUnwrap(DrillPlan.plan(for: .midSideMid))
        XCTAssertTrue(plan.progress(after: 1).isSameStep(as: plan.progress(after: 4)))
        XCTAssertFalse(plan.progress(after: 4).isSameStep(as: plan.progress(after: 5)))
        XCTAssertFalse(plan.progress(after: 14).isSameStep(as: plan.progress(after: 15)))
    }

    func test_undoStepsBack() throws {
        let plan = try XCTUnwrap(DrillPlan.plan(for: .midSideMid))
        XCTAssertEqual(plan.progress(after: 5).spot, "Baseline")
        XCTAssertEqual(plan.progress(after: 4).spot, "Elbow")
        XCTAssertEqual(plan.progress(after: -1).line, "Spot 1 of 3 · Elbow · 5 to go")
    }
}
