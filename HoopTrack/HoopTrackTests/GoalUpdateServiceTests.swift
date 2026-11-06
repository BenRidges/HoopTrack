// GoalUpdateServiceTests.swift
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class GoalUpdateServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var sut: GoalUpdateService!

    override func setUp() async throws {
        container = try HoopTrackStore.makeInMemoryContainer()
        context = container.mainContext
        sut = GoalUpdateService(modelContext: context)
    }

    override func tearDown() async throws {
        container = nil
        context   = nil
        sut       = nil
    }

    // MARK: - Helpers

    private func makeProfile() throws -> PlayerProfile {
        let p = PlayerProfile()
        context.insert(p)
        try context.save()
        return p
    }

    private func makeSession(drillType: DrillType = .freeShoot,
                              fgPercent: Double = 50) throws -> TrainingSession {
        let s = TrainingSession(drillType: drillType)
        if drillType == .freeShoot {
            s.shotsAttempted = 20
            s.shotsMade      = Int(fgPercent / 5)
        }
        s.fgPercent = fgPercent
        s.endedAt   = .now
        context.insert(s)
        try context.save()
        return s
    }

    private func makeGoal(metric: GoalMetric,
                           target: Double,
                           baseline: Double = 0,
                           for profile: PlayerProfile) throws -> GoalRecord {
        let g = GoalRecord(title: "Test", skill: .shooting, metric: metric,
                           targetValue: target, baselineValue: baseline)
        g.profile = profile
        profile.goals.append(g)
        context.insert(g)
        try context.save()
        return g
    }

    // MARK: - fgPercent

    func test_update_fgPercentGoal_updatesCurrentValue() throws {
        let profile = try makeProfile()
        let session = try makeSession(fgPercent: 45)
        let goal    = try makeGoal(metric: .fgPercent, target: 50, for: profile)

        try sut.update(after: session, profile: profile)

        XCTAssertEqual(goal.currentValue, 45, accuracy: 0.01)
        XCTAssertFalse(goal.isAchieved)
    }

    func test_update_fgPercentGoalAchieved_setsIsAchieved() throws {
        let profile = try makeProfile()
        let session = try makeSession(fgPercent: 55)
        let goal    = try makeGoal(metric: .fgPercent, target: 50, for: profile)

        try sut.update(after: session, profile: profile)

        XCTAssertTrue(goal.isAchieved)
        XCTAssertNotNil(goal.achievedAt)
    }

    func test_update_alreadyAchievedGoal_isNotTouchedAgain() throws {
        let profile = try makeProfile()
        let session = try makeSession(fgPercent: 30)
        let goal    = try makeGoal(metric: .fgPercent, target: 50, for: profile)
        goal.isAchieved = true
        goal.achievedAt = Date(timeIntervalSinceNow: -3600)
        let originalDate = goal.achievedAt

        try sut.update(after: session, profile: profile)

        XCTAssertEqual(goal.achievedAt, originalDate)
    }

    func test_update_dribbleSession_leavesShootingGoalAlone() throws {
        let profile = try makeProfile()
        let goal    = try makeGoal(metric: .fgPercent, target: 50, baseline: 40, for: profile)
        goal.currentValue = 44
        let dribble = try makeSession(drillType: .dribble, fgPercent: 0)

        try sut.update(after: dribble, profile: profile)

        XCTAssertEqual(goal.currentValue, 44, accuracy: 0.01)
    }

    func test_update_shuttleGoal_withoutShuttleRun_staysFinite() throws {
        let profile = try makeProfile()
        let goal    = try makeGoal(metric: .shuttleRunSeconds, target: 7, baseline: 9, for: profile)
        goal.currentValue = 8.5
        let session = try makeSession(drillType: .agility)

        try sut.update(after: session, profile: profile)

        XCTAssertEqual(goal.currentValue, 8.5, accuracy: 0.01)
        XCTAssertFalse(goal.isAchieved)
    }

    func test_update_shuttleGoal_lowerTimeAchieves() throws {
        let profile = try makeProfile()
        let goal    = try makeGoal(metric: .shuttleRunSeconds, target: 7, baseline: 9, for: profile)
        let session = try makeSession(drillType: .agility)
        session.bestShuttleRunSeconds = 6.8

        try sut.update(after: session, profile: profile)

        XCTAssertTrue(goal.isAchieved)
        XCTAssertEqual(goal.progressFraction, 1, accuracy: 0.001)
    }

    // MARK: - sessionsPerWeek

    func test_update_sessionsPerWeekGoal_countsRecentSessions() throws {
        let profile = try makeProfile()
        // Add 3 completed sessions in the past 7 days
        for _ in 0..<3 {
            let s = try makeSession()
            s.startedAt = Date(timeIntervalSinceNow: -86400) // yesterday
            profile.sessions.append(s)
        }
        let session = try makeSession()
        let goal    = try makeGoal(metric: .sessionsPerWeek, target: 5, for: profile)

        try sut.update(after: session, profile: profile)

        XCTAssertGreaterThan(goal.currentValue, 0)
    }

    // MARK: - overallRating

    func test_update_overallRatingGoal_readsFromProfile() throws {
        let profile = try makeProfile()
        profile.ratingOverall = 72
        let session = try makeSession()
        let goal    = try makeGoal(metric: .overallRating, target: 80, for: profile)

        try sut.update(after: session, profile: profile)

        XCTAssertEqual(goal.currentValue, 72, accuracy: 0.01)
    }
}
