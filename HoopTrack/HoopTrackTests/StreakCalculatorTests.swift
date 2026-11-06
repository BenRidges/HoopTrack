// HoopTrackTests/StreakCalculatorTests.swift
import XCTest
@testable import HoopTrack

final class StreakCalculatorTests: XCTestCase {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let today = Date(timeIntervalSince1970: 1_800_000_000)   // fixed reference day

    private func daysAgo(_ n: Int, hour: Int = 10) -> Date {
        let start = calendar.startOfDay(for: today)
        return calendar.date(byAdding: .hour, value: hour - 24 * n, to: start)!
    }

    func test_noSessions_isZero() {
        XCTAssertEqual(StreakCalculator.current(trainingDays: [], today: today, calendar: calendar), 0)
    }

    func test_trainedTodayAndTwoDaysBefore_isThree() {
        let dates = [daysAgo(0), daysAgo(1), daysAgo(2), daysAgo(4)]
        XCTAssertEqual(StreakCalculator.current(trainingDays: dates, today: today, calendar: calendar), 3)
    }

    func test_notYetToday_butYesterday_keepsStreakAlive() {
        let dates = [daysAgo(1), daysAgo(2)]
        XCTAssertEqual(StreakCalculator.current(trainingDays: dates, today: today, calendar: calendar), 2)
    }

    func test_missedAFullDay_resetsToZero() {
        let dates = [daysAgo(2), daysAgo(3), daysAgo(4)]
        XCTAssertEqual(StreakCalculator.current(trainingDays: dates, today: today, calendar: calendar), 0)
    }

    func test_multipleSessionsSameDay_countOnce() {
        let dates = [daysAgo(0, hour: 8), daysAgo(0, hour: 18), daysAgo(1)]
        XCTAssertEqual(StreakCalculator.current(trainingDays: dates, today: today, calendar: calendar), 2)
    }

    func test_longest_findsBestRun() {
        let dates = [daysAgo(10), daysAgo(9), daysAgo(8), daysAgo(7), daysAgo(3), daysAgo(2)]
        XCTAssertEqual(StreakCalculator.longest(trainingDays: dates, calendar: calendar), 4)
        XCTAssertEqual(StreakCalculator.longest(trainingDays: [], calendar: calendar), 0)
    }

    /// The current run is one of the runs `longest` looks at, so it can
    /// never be the bigger number.
    func test_longest_isNeverBelowCurrent() {
        let patterns: [[Int]] = [[], [0], [1], [0, 1], [1, 3, 5], [0, 1, 2, 9, 10], [0, 2, 3, 4], [1, 2, 3, 4, 5, 6]]
        for pattern in patterns {
            let dates = pattern.map { daysAgo($0) }
            let current = StreakCalculator.current(trainingDays: dates, today: today, calendar: calendar)
            let longest = StreakCalculator.longest(trainingDays: dates, calendar: calendar)
            XCTAssertGreaterThanOrEqual(longest, current, "days ago: \(pattern)")
        }
    }
}
