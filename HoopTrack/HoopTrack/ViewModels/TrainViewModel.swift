// TrainViewModel.swift
// Drives the Train tab — drill catalogue, filtering, and drill launch flow.

import Foundation
import Combine

@MainActor
final class TrainViewModel: ObservableObject {

    // MARK: - Published
    @Published var selectedDrillType: DrillType? = nil   // nil = show all
    @Published var selectedNamedDrill: NamedDrill?
    @Published var isShowingSessionConfig: Bool = false
    @Published var isShowingLiveSession: Bool = false

    // Session config state (shown in pre-session sheet)
    @Published var selectedCourtType: CourtType = .nba
    @Published var locationTag: String = ""

    // MARK: - Catalogue

    /// All named drills, optionally filtered by type.
    var filteredDrills: [NamedDrill] {
        guard let filter = selectedDrillType else { return NamedDrill.allCases }
        return NamedDrill.allCases.filter { $0.drillType == filter }
    }

    var drillCategories: [DrillType] { DrillType.allCases }

    // MARK: - Launch Flow

    func selectDrill(_ drill: NamedDrill) {
        selectedNamedDrill   = drill
        isShowingSessionConfig = true
    }

    func confirmAndLaunch() {
        isShowingSessionConfig = false
        isShowingLiveSession   = true
    }

    func startFreeShoot() {
        selectedNamedDrill     = nil
        isShowingSessionConfig = true
    }

    func sessionDidFinish() {
        isShowingLiveSession   = false
        selectedNamedDrill     = nil
    }

    // MARK: - Drill Metadata Helpers

    func description(for drill: NamedDrill) -> String {
        switch drill {
        case .aroundTheArc:
            return "5 spots around the 3-point arc, 5 shots each. Tracks zone accuracy."
        case .freethrowChallenge:
            return "Sets of 10 free throws. Tracks percentage and consistency over time."
        case .midSideMid:
            return "Mid-range triangle drill. 3 positions, timed."
        case .fiveMinEndurance:
            return "As many makes as possible in 5 minutes. Tracks fatigue curve."
        case .mikanDrill:
            return "Alternating-hand layup loop. Tracks makes per 60 seconds."
        case .crossoverSeries:
            return "AR targets guide dribble direction. Combo tracking enabled."
        case .twoBallDribble:
            return "Simultaneous dribble with both hands. Balance score output."
        case .shuttleRun:
            return "Lateral sprint between two AR cones. 3-rep average."
        case .laneAgility:
            return "Box-step footwork drill. Timed to nearest 0.01 second."
        case .verticalJumpTest:
            return "3 attempts. Best jump height recorded and saved to profile."
        }
    }
}
