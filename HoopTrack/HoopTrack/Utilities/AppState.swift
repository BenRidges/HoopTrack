// AppState.swift
// Shared navigation state: selected tab and the live session being shown.
// Deep links (Siri, notifications) route through here.

import SwiftUI
import Combine

enum AppTab: Hashable {
    case train, progress, profile
}

/// A training session to present full screen.
enum TrainingLaunch: Identifiable, Equatable {
    case shooting(NamedDrill?)
    case dribble(NamedDrill)
    case agility(NamedDrill)
    case game
    /// A sitting of the playoff run with this PlayoffSeries id.
    case playoff(UUID)

    var id: String {
        switch self {
        case .shooting(let drill): return "shoot-\(drill?.rawValue ?? "free")"
        case .dribble(let drill):  return "dribble-\(drill.rawValue)"
        case .agility(let drill):  return "agility-\(drill.rawValue)"
        case .game:                return "game"
        case .playoff(let id):     return "playoff-\(id.uuidString)"
        }
    }

    /// The right session type for a library drill.
    static func forDrill(_ drill: NamedDrill) -> TrainingLaunch {
        switch drill.drillType {
        case .dribble:              return .dribble(drill)
        case .agility:              return .agility(drill)
        case .freeShoot, .fullWorkout: return .shooting(drill)
        }
    }
}

/// A finished session waiting to be shown in the summary sheet.
struct CompletedSession: Identifiable {
    let id = UUID()
    let result: SessionResult
}

@MainActor
final class AppState: ObservableObject {

    @Published var selectedTab: AppTab = .train
    @Published var activeLaunch: TrainingLaunch?
    /// Summary on screen right now.
    @Published var presentedSummary: CompletedSession?
    /// Summary to show once the live session has finished dismissing.
    private var queuedSummary: CompletedSession?

    /// Called by every live session when it ends. The summary is shown after
    /// the full-screen session has gone, back in portrait.
    func finishSession(with result: SessionResult?) {
        queuedSummary = result.map(CompletedSession.init(result:))
        activeLaunch = nil
    }

    /// Hooked to the session cover's onDismiss.
    func sessionCoverDismissed() {
        presentedSummary = queuedSummary
        queuedSummary = nil
    }

    /// Handles `hooptrack://` URLs:
    ///   hooptrack://shoot     start a shooting session now
    ///   hooptrack://train     Train tab
    ///   hooptrack://progress  Progress tab
    ///   hooptrack://profile   Profile tab
    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "hooptrack" else { return }
        switch url.host?.lowercased() {
        case "shoot":
            selectedTab = .train
            if activeLaunch == nil { activeLaunch = .shooting(nil) }
        case "train":    selectedTab = .train
        case "progress": selectedTab = .progress
        case "profile":  selectedTab = .profile
        default:         break
        }
    }
}
