// StreakCalculator.swift
// Day-streak maths from the dates you trained on. A streak is alive while
// your last session was today or yesterday, and dies the day after that —
// the old stored counter only ever updated when you trained, so it kept
// showing a long streak weeks after you'd stopped.

import Foundation

nonisolated enum StreakCalculator {

    /// Consecutive training days ending today (or yesterday, if you haven't
    /// trained yet today). Zero once a full day has been missed.
    static func current(trainingDays dates: [Date], today: Date = .now, calendar: Calendar = .current) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        var cursor = calendar.startOfDay(for: today)
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// Longest run of consecutive training days ever.
    static func longest(trainingDays dates: [Date], calendar: Calendar = .current) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) }).sorted()
        var best = 0, run = 0
        var previous: Date?
        for day in days {
            if let previous,
               let next = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(next, inSameDayAs: day) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }
}
