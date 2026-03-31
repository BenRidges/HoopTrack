// ProgressViewModel.swift
// Drives the Progress tab — trend charts, heat map data,
// zone efficiency, and goal tracking.

import Foundation
import Combine

@MainActor
final class ProgressViewModel: ObservableObject {

    // MARK: - Published
    @Published var sessions: [TrainingSession] = []
    @Published var goals: [GoalRecord] = []
    @Published var fgTrendData: [(date: Date, fg: Double)] = []
    @Published var weeklyVolume: [(date: Date, attempts: Int)] = []
    @Published var selectedTimeRange: TimeRange = .last30Days
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - Dependencies
    private let dataService: DataService
    private var cancellables = Set<AnyCancellable>()

    init(dataService: DataService) {
        self.dataService = dataService

        // Re-fetch when time range changes
        $selectedTimeRange
            .sink { [weak self] _ in self?.load() }
            .store(in: &cancellables)
    }

    // MARK: - Load

    func load() {
        isLoading = true
        do {
            sessions     = try dataService.fetchSessions()
            weeklyVolume = try dataService.dailyVolume(lastDays: selectedTimeRange.days)
            fgTrendData  = computeFGTrend()

            let profile  = try dataService.fetchOrCreateProfile()
            goals        = profile.goals
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - FG% Trend

    private func computeFGTrend() -> [(date: Date, fg: Double)] {
        let cutoff = Calendar.current.date(byAdding: .day,
                                           value: -selectedTimeRange.days,
                                           to: .now)!
        let inRange = sessions.filter { $0.startedAt >= cutoff && $0.isComplete }

        // Group by day, compute daily FG%
        var byDay: [Date: (made: Int, attempted: Int)] = [:]
        for s in inRange {
            let day = Calendar.current.startOfDay(for: s.startedAt)
            byDay[day, default: (0, 0)].made      += s.shotsMade
            byDay[day, default: (0, 0)].attempted += s.shotsAttempted
        }

        return byDay
            .sorted { $0.key < $1.key }
            .compactMap { day, stats -> (Date, Double)? in
                guard stats.attempted > 0 else { return nil }
                return (day, Double(stats.made) / Double(stats.attempted) * 100)
            }
    }

    // MARK: - Shot Heat Map Data

    /// Returns shot records within the selected time range for heat map rendering.
    var heatMapShots: [ShotRecord] {
        let cutoff = Calendar.current.date(byAdding: .day,
                                           value: -selectedTimeRange.days,
                                           to: .now)!
        return sessions
            .filter { $0.startedAt >= cutoff }
            .flatMap { $0.shots }
            .filter { $0.result != .pending }
    }

    // MARK: - Zone Efficiency

    struct ZoneEfficiency: Identifiable {
        let id = UUID()
        let zone: CourtZone
        let attempted: Int
        let made: Int
        var fgPercent: Double { attempted > 0 ? Double(made) / Double(attempted) * 100 : 0 }
        var trend: Double = 0   // positive = improving (Phase 5: compute from time series)
    }

    var zoneEfficiency: [ZoneEfficiency] {
        var stats: [CourtZone: (made: Int, attempted: Int)] = [:]
        for shot in heatMapShots {
            stats[shot.zone, default: (0, 0)].attempted += 1
            if shot.result == .make { stats[shot.zone, default: (0, 0)].made += 1 }
        }
        return stats.map { zone, s in
            ZoneEfficiency(zone: zone, attempted: s.attempted, made: s.made)
        }
        .sorted { $0.attempted > $1.attempted }
    }

    // MARK: - Personal Records (displayed in Progress tab)

    var bestSession: TrainingSession? {
        sessions.filter { $0.isComplete && $0.shotsAttempted >= 5 }
                .max { $0.fgPercent < $1.fgPercent }
    }

    var mostActiveSession: TrainingSession? {
        sessions.max { $0.shotsAttempted < $1.shotsAttempted }
    }
}

// MARK: - TimeRange
enum TimeRange: String, CaseIterable, Identifiable {
    case last7Days  = "7 Days"
    case last30Days = "30 Days"
    case last90Days = "90 Days"
    case allTime    = "All Time"

    var id: String { rawValue }
    var days: Int {
        switch self {
        case .last7Days:  return 7
        case .last30Days: return 30
        case .last90Days: return 90
        case .allTime:    return 36500  // ~100 years = effectively all time
        }
    }
}
