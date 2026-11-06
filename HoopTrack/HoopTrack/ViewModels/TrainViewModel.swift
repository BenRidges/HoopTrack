// TrainViewModel.swift
// The Train tab's "this week" strip, playoff run and last-session row.

import Foundation
import Combine

@MainActor
final class TrainViewModel: ObservableObject {
    deinit {} // Keep: see "Explicit deinit" in CLAUDE.md


    struct Week: Equatable {
        var shots = 0
        var makes = 0
        var sessions = 0
        var minutes = 0.0
        var fgPercent: Double? { shots > 0 ? Double(makes) / Double(shots) * 100 : nil }
    }

    @Published private(set) var playerName = ""
    @Published private(set) var week = Week()
    @Published private(set) var streak = 0
    @Published private(set) var lastSession: TrainingSession?
    @Published private(set) var hasHistory = false
    /// The playoff run in progress, replayed fresh (loading never writes).
    @Published private(set) var playoff: (series: PlayoffSeries, run: PlayoffRun)?

    func load(from dataService: DataService) {
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? calendar.startOfDay(for: .now)
        let thisWeek = (try? dataService.fetchSessions(since: weekStart)) ?? []

        week = Week(shots: thisWeek.reduce(0) { $0 + $1.shotsAttempted },
                    makes: thisWeek.reduce(0) { $0 + $1.shotsMade },
                    sessions: thisWeek.count,
                    minutes: thisWeek.reduce(0) { $0 + $1.durationSeconds } / 60)

        let profile = try? dataService.fetchOrCreateProfile()
        playerName = profile?.name ?? ""
        streak = profile?.currentStreakDays ?? 0
        lastSession = (try? dataService.fetchSessions(limit: 1))?.first
        hasHistory = lastSession != nil
        playoff = dataService.activePlayoffSeries().map { ($0, dataService.playoffRun(for: $0)) }
    }

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Morning" : hour < 18 ? "Afternoon" : "Evening"
        let name = playerName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "Player" ? part : "\(part), \(name)"
    }
}
