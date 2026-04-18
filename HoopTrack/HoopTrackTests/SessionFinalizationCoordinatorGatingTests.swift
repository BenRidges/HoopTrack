// SessionFinalizationCoordinatorGatingTests.swift
// Covers the pure-function badge-skip gate. The coordinator itself is stateful
// and not unit-testable per the project convention, but the gating decision is
// isolated into a pure static helper.

import XCTest
@testable import HoopTrack

final class SessionFinalizationCoordinatorGatingTests: XCTestCase {

    private var threshold: Int { HoopTrack.SkillRating.badgeMinShotsForShootingSession }

    // MARK: - freeShoot below threshold → skip

    func test_freeShoot_underThreshold_returnsSkipReason() {
        let reason = SessionFinalizationCoordinator.badgeSkipReason(
            drillType: .freeShoot,
            shotsAttempted: threshold - 1
        )
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("\(threshold)"),
                       "Skip reason should mention the shot threshold so the UI is self-explanatory")
    }

    func test_freeShoot_zeroShots_returnsSkipReason() {
        XCTAssertNotNil(SessionFinalizationCoordinator.badgeSkipReason(
            drillType: .freeShoot,
            shotsAttempted: 0
        ))
    }

    // MARK: - freeShoot at or above threshold → evaluate

    func test_freeShoot_atThreshold_returnsNil() {
        XCTAssertNil(SessionFinalizationCoordinator.badgeSkipReason(
            drillType: .freeShoot,
            shotsAttempted: threshold
        ))
    }

    func test_freeShoot_wellAboveThreshold_returnsNil() {
        XCTAssertNil(SessionFinalizationCoordinator.badgeSkipReason(
            drillType: .freeShoot,
            shotsAttempted: threshold + 100
        ))
    }

    // MARK: - non-shooting drills are never skipped by shot count

    func test_dribble_withZeroShots_returnsNil() {
        XCTAssertNil(SessionFinalizationCoordinator.badgeSkipReason(
            drillType: .dribble,
            shotsAttempted: 0
        ))
    }

    func test_agility_withZeroShots_returnsNil() {
        XCTAssertNil(SessionFinalizationCoordinator.badgeSkipReason(
            drillType: .agility,
            shotsAttempted: 0
        ))
    }

    func test_fullWorkout_withZeroShots_returnsNil() {
        XCTAssertNil(SessionFinalizationCoordinator.badgeSkipReason(
            drillType: .fullWorkout,
            shotsAttempted: 0
        ))
    }
}
