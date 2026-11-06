// ProgressViewModel.swift
// Everything on the Progress tab for one time range.
//
// The old version reloaded from a `$selectedTimeRange` sink, which fires
// *before* the property changes — so every pick showed the previous range.
// Loads are now explicit and take the range as an argument.

import Foundation
import Combine

enum TimeRange: String, CaseIterable, Identifiable {
    case last7Days  = "7D"
    case last30Days = "30D"
    case last90Days = "90D"
    case allTime    = "All"

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .last7Days:  return 7
        case .last30Days: return 30
        case .last90Days: return 90
        case .allTime:    return nil
        }
    }

    var phrase: String {
        switch self {
        case .last7Days:  return "last 7 days"
        case .last30Days: return "last 30 days"
        case .last90Days: return "last 90 days"
        case .allTime:    return "all time"
        }
    }

    /// Daily points for short ranges, weekly for long ones.
    var bucket: Calendar.Component { (days ?? 365) <= 30 ? .day : .weekOfYear }
}

@MainActor
final class ProgressViewModel: ObservableObject {

    struct TrendPoint: Identifiable, Equatable {
        let date: Date
        let fgPercent: Double
        let attempts: Int
        var id: Date { date }
    }

    struct ZoneLine: Identifiable, Equatable {
        let zone: CourtZone
        let made: Int
        let attempted: Int
        var id: CourtZone { zone }
        var percent: Double { attempted > 0 ? Double(made) / Double(attempted) * 100 : 0 }
    }

    @Published private(set) var range: TimeRange = .last30Days
    @Published private(set) var shots = 0
    @Published private(set) var makes = 0
    @Published private(set) var sessionCount = 0
    @Published private(set) var minutes = 0.0
    @Published private(set) var previousFG: Double?
    @Published private(set) var trend: [TrendPoint] = []
    @Published private(set) var chartShots: [ShotRecord] = []
    @Published private(set) var zones: [ZoneLine] = []
    @Published private(set) var profile: PlayerProfile?
    @Published private(set) var recentSessions: [TrainingSession] = []
    @Published private(set) var hasAnySessions = false

    var fgPercent: Double? { shots > 0 ? Double(makes) / Double(shots) * 100 : nil }

    var fgChange: Double? {
        guard let now = fgPercent, let before = previousFG else { return nil }
        return now - before
    }

    func load(range: TimeRange, from dataService: DataService) {
        self.range = range
        let calendar = Calendar.current
        let cutoff = range.days.flatMap { calendar.date(byAdding: .day, value: -$0, to: .now) } ?? .distantPast

        let all = (try? dataService.fetchSessions()) ?? []
        hasAnySessions = !all.isEmpty
        recentSessions = Array(all.prefix(5))
        profile = try? dataService.fetchOrCreateProfile()

        let inRange = all.filter { $0.startedAt >= cutoff }
        sessionCount = inRange.count
        minutes = inRange.reduce(0) { $0 + $1.durationSeconds } / 60

        let shooting = inRange.filter { $0.shotsAttempted > 0 }
        shots = shooting.reduce(0) { $0 + $1.shotsAttempted }
        makes = shooting.reduce(0) { $0 + $1.shotsMade }

        // Same-length window just before this one, for the "+4 pts" delta.
        if let days = range.days,
           let previousStart = calendar.date(byAdding: .day, value: -days, to: cutoff) {
            let previous = all.filter { $0.startedAt >= previousStart && $0.startedAt < cutoff }
            let attempted = previous.reduce(0) { $0 + $1.shotsAttempted }
            let made = previous.reduce(0) { $0 + $1.shotsMade }
            previousFG = attempted >= 10 ? Double(made) / Double(attempted) * 100 : nil
        } else {
            previousFG = nil
        }

        trend = Self.trend(for: shooting, bucket: range.bucket, calendar: calendar)

        let rangeShots = shooting.flatMap(\.shots).filter { $0.result != .pending }
        chartShots = rangeShots
        var byZone: [CourtZone: (made: Int, attempted: Int)] = [:]
        for shot in rangeShots where shot.zone != .unknown {
            byZone[shot.zone, default: (0, 0)].attempted += 1
            if shot.isMake { byZone[shot.zone, default: (0, 0)].made += 1 }
        }
        zones = byZone
            .map { ZoneLine(zone: $0.key, made: $0.value.made, attempted: $0.value.attempted) }
            .sorted { $0.attempted > $1.attempted }
    }

    static func trend(for sessions: [TrainingSession], bucket: Calendar.Component,
                      calendar: Calendar) -> [TrendPoint] {
        var groups: [Date: (made: Int, attempted: Int)] = [:]
        for session in sessions {
            let key = calendar.dateInterval(of: bucket, for: session.startedAt)?.start
                ?? calendar.startOfDay(for: session.startedAt)
            groups[key, default: (0, 0)].made += session.shotsMade
            groups[key, default: (0, 0)].attempted += session.shotsAttempted
        }
        return groups
            .filter { $0.value.attempted > 0 }
            .map { TrendPoint(date: $0.key,
                              fgPercent: Double($0.value.made) / Double($0.value.attempted) * 100,
                              attempts: $0.value.attempted) }
            .sorted { $0.date < $1.date }
    }
}
