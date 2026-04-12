// DashboardViewModel.swift
// Drives the Home tab — skill ratings, streaks, personal records,
// weekly volume bar chart data, and the daily mission suggestion.

import Foundation
import Combine
import SwiftData

@MainActor
final class DashboardViewModel: ObservableObject {

    // MARK: - Published
    @Published var profile: PlayerProfile?

    @Published var shootingFGLast7:  Double = 0
    @Published var shootingFGLast30: Double = 0
    @Published var weeklyVolume: [(date: Date, attempts: Int)] = []

    @Published var dailyMissionDrill: NamedDrill = .aroundTheArc
    @Published var dailyMissionSkill: SkillDimension = .shooting

    @Published var isLoading: Bool  = false
    @Published var errorMessage: String?

    // MARK: - Dependencies
    private let dataService: DataService

    init(dataService: DataService) {
        self.dataService = dataService
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        do {
            profile       = try dataService.fetchOrCreateProfile()
            shootingFGLast7  = try dataService.fgPercent(lastDays: 7)
            shootingFGLast30 = try dataService.fgPercent(lastDays: 30)
            weeklyVolume     = try dataService.dailyVolume(lastDays: 7)
            updateDailyMission()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Skill Rating Helpers

    var overallRating: Double { profile?.ratingOverall ?? 0 }

    var skillRatings: [(skill: SkillDimension, value: Double)] {
        guard let p = profile else { return [] }
        return SkillDimension.allCases.map { skill in
            (skill: skill, value: p.skillRatings[skill] ?? 0)
        }
    }

    // MARK: - Streak

    var currentStreak: Int  { profile?.currentStreakDays ?? 0 }
    var longestStreak: Int  { profile?.longestStreakDays ?? 0 }

    // MARK: - Personal Records

    var prBestFG:      String { String(format: "%.1f%%", profile?.prBestFGPercentSession ?? 0) }
    var prMostMakes:   Int    { profile?.prMostMakesSession ?? 0 }
    var prVertical:    String { String(format: "%.0f cm", profile?.prVerticalJumpCm ?? 0) }
    var prConsistency: String {
        guard let score = profile?.prBestConsistencyScore,
              score != Double.infinity else { return "—" }
        return String(format: "%.1f°", score)
    }

    // MARK: - Daily Mission

    private func updateDailyMission() {
        guard let p = profile else { return }

        // Find weakest skill dimension
        let weakest = SkillDimension.allCases.min {
            (p.skillRatings[$0] ?? 0) < (p.skillRatings[$1] ?? 0)
        } ?? .shooting

        dailyMissionSkill = weakest

        // Map skill to a suggested drill
        dailyMissionDrill = {
            switch weakest {
            case .shooting:     return .aroundTheArc
            case .ballHandling: return .crossoverSeries
            case .athleticism:  return .verticalJumpTest
            case .consistency:  return .freethrowChallenge
            case .volume:       return .fiveMinEndurance
            }
        }()
    }

    // MARK: - Recent Session

    var lastSessionSummary: TrainingSession? {
        profile?.sessions
            .filter { $0.isComplete }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }
}
