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
        container = try ModelContainer(
            for: PlayerProfile.self, TrainingSession.self,
                 ShotRecord.self, GoalRecord.self, EarnedBadge.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
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
