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
    /// One short line shown over the tabs for a few seconds.
    @Published var notice: String?
    /// How the live session ended, acted on once it has finished dismissing.
    private var queuedEnd: SessionEnd?

    static let discardedNotice = "Nothing was recorded, so the session wasn't saved."

    /// Called by every live session when it closes; nil when there's
    /// nothing to report (a game, or closing after a failed save). The
    /// summary or notice follows once the full-screen session has gone,
    /// back in portrait.
    func finishSession(with end: SessionEnd?) {
        queuedEnd = end
        activeLaunch = nil
    }

    /// Hooked to the session cover's onDismiss.
    func sessionCoverDismissed() {
        switch queuedEnd {
        case .saved(let result):
            presentedSummary = CompletedSession(result: result)
        case .discarded:
            // Without this the session just vanished, which read as a crash.
            notice = Self.discardedNotice
        case .failed, nil:
            break
        }
        queuedEnd = nil
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
